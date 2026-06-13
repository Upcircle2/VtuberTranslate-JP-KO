import Foundation
import Speech
import AVFAudio
import CoreMedia
import Accelerate

/// macOS 26 SpeechAnalyzer / SpeechTranscriber 기반 온디바이스 스트리밍 인식기.
///
/// SpeechTranscriber.Result에는 isFinal이 없으므로(SpeechDetector 전용),
/// result.range.start의 전진으로 '확정 세그먼트 + 교체형 volatile 꼬리'를 직접 재구성한다.
final class AppleSpeechRecognizer: SpeechRecognizing {
    var onUpdate: ((TranscriptionUpdate) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    // 전사 누적(결과 태스크에서만 접근). 발화(utterance) 한 덩어리만 보유 → 끝나면 비운다.
    private struct Segment { let start: Double; var text: String }
    private var segments: [Segment] = []
    private var committedCount = 0
    private var lastEmittedFull = ""              // LocalAgreement-2: 직전 가설(공통 접두 확정용)
    private var maxConfirmedLen = 0               // 확정 경계 단조 증가(후퇴 방지 → 매끄러움)
    private var joinSeparator = ""
    private let segmentGapTolerance = 0.35

    // 자막 라인 리셋(클리어) 조건
    private let maxLineChars = 70                 // 이보다 길어지면 다음 발화에서 비움(2줄 UI가 축소로 흡수 가능한 선)
    private let confidenceThreshold = 0.80        // 이 미만 신뢰도는 환각으로 보고 무시(무발화 잡음 차단)
    private var pendingClear = false
    private static let sentenceEnders: Set<Character> = ["。", "．", ".", "！", "!", "？", "?", "…"]

    // PTS(append 스레드에서만 접근)
    private var firstInputTime: CMTime?
    private var lastInputTime: CMTime = .zero

    // RMS VAD(append 스레드에서 갱신, emit에서 commitTailRequested/pendingClear만 읽음)
    private let vadSilenceThreshold: Float = 0.008
    private let vadHangoverSeconds = 0.6          // 이만큼 무음 → 꼬리 강제 확정(finalize)
    private let utteranceResetSeconds = 1.8       // 이만큼 무음 → 발화 종료로 보고 라인 클리어(짧은 쉼엔 안 비움)
    private var silenceSeconds = 0.0
    private var awaitingFinalize = false
    private var commitTailRequested = false

    // 스피치 게이트: 발화 레벨 이하(룸톤/노이즈)는 디지털 묵음으로 대체 → 무발화 환각 방지
    private let speechGateThreshold: Float = 0.012
    private let gateHangoverSeconds = 0.35        // 말끝 잘림 방지용 여유
    private var gateSilence = 0.0
    private var gateOpen = false

    enum RecognizerError: Error { case notAuthorized }

    func prewarm(locale: Locale) async {
        let probe = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        _ = try? await AssetInventory.reserve(locale: locale)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try? await request.downloadAndInstall()
        }
    }

    func start(locale: Locale) async throws {
        let status = await Self.requestAuthorization()
        guard status == .authorized else { throw RecognizerError.notAuthorized }

        resetState(for: locale)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        self.transcriber = transcriber

        // 해당 언어 모델이 없으면 내려받는다.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // 음성활동탐지(VAD): 음악/노이즈 등 비발화 구간 전사를 막아 무발화 환각을 줄인다.
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: false
        )

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber, detector])
        analyzerFormat = format

        let analyzer = SpeechAnalyzer(
            modules: [transcriber, detector],
            options: SpeechAnalyzer.Options(priority: .high, modelRetention: .whileInUse)
        )
        self.analyzer = analyzer

        // 모델을 미리 준비해 첫 토큰 콜드스타트를 줄인다(오디오 주입 없이 예열).
        try? await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [weak self] in
            guard let transcriber = self?.transcriber else { return }
            do {
                for try await result in transcriber.results {
                    self?.handleResult(text: String(result.text.characters),
                                       start: result.range.start.seconds,
                                       confidence: Self.averageConfidence(result.text))
                }
            } catch {
                // 스트림 종료 또는 오류 — 조용히 끝낸다.
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        guard let continuation = inputContinuation, let analyzerFormat else { return }
        guard let converted = convert(buffer, to: analyzerFormat) else { return }

        let rms = Self.rms(of: buffer)
        let durationSec = Double(buffer.frameLength) / buffer.format.sampleRate

        // 발화 레벨 이하 구간은 디지털 묵음으로 대체 → 분석기가 노이즈를 헛받아쓰는 환각 방지.
        updateSpeechGate(rms: rms, duration: durationSec)
        if !gateOpen { Self.zero(converted) }

        if firstInputTime == nil { firstInputTime = time }
        let start = CMTimeSubtract(time, firstInputTime ?? time)
        let duration = CMTime(seconds: durationSec, preferredTimescale: 48_000)
        lastInputTime = CMTimeAdd(start, duration)
        continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))

        detectSilenceAndFinalize(rms: rms, bufferDuration: durationSec)
    }

    private func updateSpeechGate(rms: Float, duration: Double) {
        if rms >= speechGateThreshold {
            gateOpen = true
            gateSilence = 0
        } else {
            gateSilence += duration
            if gateSilence >= gateHangoverSeconds { gateOpen = false }
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 1 }   // 알 수 없으면 발화로 간주
        var r: Float = 0
        vDSP_rmsqv(channels[0], 1, &r, vDSP_Length(buffer.frameLength))
        return r
    }

    private static func zero(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        for c in 0..<Int(buffer.format.channelCount) {
            memset(channels[c], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
    }

    func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        analyzerFormat = nil
        resetState(for: nil)
    }

    // MARK: 전사 재구성

    private func handleResult(text: String, start: Double, confidence: Double) {
        // 저신뢰 결과(무발화 구간의 환각 가능성)는 무시 → 멀쩡한 줄을 끊지 않는다.
        // 실제 발화는 신뢰도 ~0.88+ 이라 0.80 임계는 정상 발화를 거의 건드리지 않는다.
        guard confidence >= confidenceThreshold else { return }

        let isNewSegment = segments.last.map { start > $0.start + segmentGapTolerance } ?? true

        if isNewSegment {
            // 클리어는 '진짜 새 발화'일 때만 — 같은 발화의 개정(종결부호 삽입 등)엔 라인을 유지해 깜빡임 방지.
            if pendingClear {
                segments.removeAll()
                committedCount = 0
                lastEmittedFull = ""
                maxConfirmedLen = 0
                pendingClear = false
            } else if !segments.isEmpty {
                committedCount = segments.count            // 직전 세그먼트들 확정
            }
            segments.append(Segment(start: start, text: text))
            commitTailRequested = false
        } else {
            segments[segments.count - 1].text = text       // 같은 발화 갱신(개정 포함)
            if commitTailRequested {
                committedCount = segments.count             // 무음 감지 → 꼬리까지 확정
                commitTailRequested = false
            }
        }

        let full = segments.map(\.text).joined(separator: joinSeparator)
        guard !full.isEmpty else { return }

        // 확정 경계 = 확정 세그먼트 ∪ LocalAgreement-2(직전 가설 공통접두). 발화 내에서 단조 증가
        // (후퇴하지 않음) → 흰→회 깜빡임 없이 앞 어절부터 매끄럽게 잠긴다.
        let committedLen = segments.prefix(committedCount).map(\.text).joined(separator: joinSeparator).count
        let agreedLen = Self.commonPrefixCount(full, lastEmittedFull)
        lastEmittedFull = full
        maxConfirmedLen = max(maxConfirmedLen, max(committedLen, agreedLen))
        let cc = min(maxConfirmedLen, full.count)
        onUpdate?(TranscriptionUpdate(text: full, confirmedCharCount: cc, confidence: confidence))

        // 문장이 끝났거나 너무 길어지면, 다음 발화 때 라인을 비우도록 예약(현재 줄은 그대로 보여줌).
        if let lastChar = full.reversed().first(where: { !$0.isWhitespace }),
           Self.sentenceEnders.contains(lastChar) {
            pendingClear = true
        } else if full.count >= maxLineChars {
            pendingClear = true
        }
    }

    // MARK: VAD → finalize(through:)

    private func detectSilenceAndFinalize(rms: Float, bufferDuration: Double) {
        if rms < vadSilenceThreshold {
            silenceSeconds += bufferDuration
            if silenceSeconds >= vadHangoverSeconds, !awaitingFinalize {
                awaitingFinalize = true
                commitTailRequested = true
                let target = lastInputTime
                let analyzer = self.analyzer
                Task { try? await analyzer?.finalize(through: target) }
            }
            if silenceSeconds >= utteranceResetSeconds {
                pendingClear = true        // 발화 종료 → 다음 말이 시작되면 라인 클리어
            }
        } else {
            silenceSeconds = 0
            awaitingFinalize = false
        }
    }

    // MARK: 보조

    private static func averageConfidence(_ attributed: AttributedString) -> Double {
        var sum = 0.0, count = 0
        for run in attributed.runs {
            if let c = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                sum += c
                count += 1
            }
        }
        return count == 0 ? 1.0 : sum / Double(count)
    }

    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var count = 0
        var ia = a.startIndex, ib = b.startIndex
        while ia < a.endIndex && ib < b.endIndex && a[ia] == b[ib] {
            count += 1; ia = a.index(after: ia); ib = b.index(after: ib)
        }
        return count
    }

    private func resetState(for locale: Locale?) {
        segments.removeAll()
        committedCount = 0
        lastEmittedFull = ""
        maxConfirmedLen = 0
        pendingClear = false
        firstInputTime = nil
        lastInputTime = .zero
        silenceSeconds = 0
        awaitingFinalize = false
        commitTailRequested = false
        gateSilence = 0
        gateOpen = false
        if let locale {
            let code = locale.language.languageCode
            joinSeparator = (code == .japanese || code == .chinese || code == .korean) ? "" : " "
        }
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// 캡처 포맷을 분석기가 요구하는 포맷으로 변환한다.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format {
            let newConverter = AVAudioConverter(from: buffer.format, to: format)
            newConverter?.primeMethod = .none       // 프라이밍 지연 제거
            converter = newConverter
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}
