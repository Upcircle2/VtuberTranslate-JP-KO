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
    private var joinSeparator = ""
    private let segmentGapTolerance = 0.35

    // 자막 라인 리셋(클리어) 조건
    private let maxLineChars = 70                 // 이보다 길어지면 다음 발화에서 비움(2줄 UI가 축소로 흡수 가능한 선)
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
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        // 해당 언어 모델이 없으면 내려받는다.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        analyzerFormat = format

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
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
                                       start: result.range.start.seconds)
                }
            } catch {
                // 스트림 종료 또는 오류 — 조용히 끝낸다.
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        guard let continuation = inputContinuation, let analyzerFormat else { return }
        guard let converted = convert(buffer, to: analyzerFormat) else { return }

        if firstInputTime == nil { firstInputTime = time }
        let start = CMTimeSubtract(time, firstInputTime ?? time)
        let duration = CMTime(seconds: Double(buffer.frameLength) / buffer.format.sampleRate,
                              preferredTimescale: 48_000)
        lastInputTime = CMTimeAdd(start, duration)
        continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))

        detectSilenceAndFinalize(buffer, bufferDuration: duration.seconds)
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

    private func handleResult(text: String, start: Double) {
        // 직전 발화가 끝났으면(종결부호/긴 침묵/길이초과) 새 발화 전에 라인을 비운다.
        if pendingClear {
            segments.removeAll()
            committedCount = 0
            pendingClear = false
        }

        if let last = segments.last {
            if start > last.start + segmentGapTolerance {
                committedCount = segments.count            // 직전 세그먼트들 확정
                segments.append(Segment(start: start, text: text))
                commitTailRequested = false                // 새 발화 → 보류 커밋 무효화
            } else {
                segments[segments.count - 1].text = text   // volatile 꼬리 갱신
                if commitTailRequested {
                    committedCount = segments.count         // 무음 감지 → 꼬리까지 확정
                    commitTailRequested = false
                }
            }
        } else {
            segments.append(Segment(start: start, text: text))
            commitTailRequested = false
        }

        let full = segments.map(\.text).joined(separator: joinSeparator)
        guard !full.isEmpty else { return }
        let confirmed = segments.prefix(committedCount).map(\.text).joined(separator: joinSeparator)
        onUpdate?(TranscriptionUpdate(text: full, confirmedCharCount: min(confirmed.count, full.count)))

        // 문장이 끝났거나 너무 길어지면, 다음 발화 때 라인을 비우도록 예약(현재 줄은 그대로 보여줌).
        if let lastChar = full.reversed().first(where: { !$0.isWhitespace }),
           Self.sentenceEnders.contains(lastChar) {
            pendingClear = true
        } else if full.count >= maxLineChars {
            pendingClear = true
        }
    }

    // MARK: VAD → finalize(through:)

    private func detectSilenceAndFinalize(_ buffer: AVAudioPCMBuffer, bufferDuration: Double) {
        guard let channels = buffer.floatChannelData else { return }
        var rms: Float = 0
        vDSP_rmsqv(channels[0], 1, &rms, vDSP_Length(buffer.frameLength))

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

    private func resetState(for locale: Locale?) {
        segments.removeAll()
        committedCount = 0
        pendingClear = false
        firstInputTime = nil
        lastInputTime = .zero
        silenceSeconds = 0
        awaitingFinalize = false
        commitTailRequested = false
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
