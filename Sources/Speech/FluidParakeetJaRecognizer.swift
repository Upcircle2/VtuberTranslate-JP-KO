import Foundation
import FluidAudio
import AVFAudio
import CoreMedia

/// FluidAudio의 Parakeet-TDT Japanese(batch, 온디바이스 CoreML) 기반 인식기.
/// 정확도가 높은 대신 batch라, 발화를 누적하며 ~1.2초마다 전체를 재인식해 진행 표시하고,
/// 무음(발화 종료) 시 확정 + 버퍼를 비운다.
///
/// `vocabulary`가 비어있지 않으면(이름 부스팅 ON), 확정 시 CustomVocabulary CTC 리스코어링으로
/// 멤버 이름을 보정 시도한다(실험적: CTC 스포터가 영어 학습이라 일본어 효과 미검증).
/// 부스팅 준비/실행이 실패해도 기본 받아쓰기는 그대로 진행한다(폴백).
final class FluidParakeetJaRecognizer: SpeechRecognizing {
    var onUpdate: ((TranscriptionUpdate) -> Void)?
    var vocabulary: [String] = []          // 비어있으면 이름 부스팅 비활성

    private var manager: AsrManager?
    private var spotter: CtcKeywordSpotter?
    private var rescorer: VocabularyRescorer?
    private var customVocab: CustomVocabularyContext?
    private let converter = AudioConverter()

    private enum FeedEvent { case audio([Float]) }
    private var feed: AsyncStream<FeedEvent>.Continuation?
    private var consumer: Task<Void, Never>?

    // 사람 목소리 판정용 Silero VAD(음악·게임소리·노이즈를 발화와 구별 → 무발화 환각 차단의 핵심).
    private var vad: VadManager?

    private let vadWindowSamples = 4_096             // Silero 모델 네이티브 윈도우(256ms)
    private let firstTranscribeSamples = 4_800       // 발화 첫 인식은 ~0.3초에 빨리(첫 토큰 지연↓)
    private let transcribeIntervalSamples = 11_200   // 이후 ~0.7초마다 진행 재인식(매끄러움·확정속도↑)
    private let longBufferSamples = 96_000           // ~6초 이상이면(매 재인식이 비쌈)
    private let longInterval = 19_200                // ~1.2초로 간격을 늘려 CPU↓(저사양 보호)
    private let confidenceThreshold = 0.6            // 이 미만(저신뢰 환각)은 무시
    private let maxUtteranceSamples = 224_000        // ~14초 안전 상한(모델 윈도우)

    func prewarm(locale: Locale) async {
        _ = try? await AsrModels.downloadAndLoad(version: .tdtJa)
        vad = try? await VadManager()
        if !vocabulary.isEmpty {
            _ = try? await CtcModels.downloadAndLoad(variant: .ctc110m)
        }
    }

    func start(locale: Locale) async throws {
        let models = try await AsrModels.downloadAndLoad(version: .tdtJa)
        manager = AsrManager(models: models)
        if vad == nil { vad = try? await VadManager() }
        if !vocabulary.isEmpty { await setupBoosting() }

        let (stream, continuation) = AsyncStream<FeedEvent>.makeStream()
        feed = continuation
        consumer = Task { [weak self] in
            var buffer: [Float] = []        // 목소리로 확정된 발화만 누적
            var lastCount = 0
            var firstEmitDone = false       // 발화의 첫 인식 여부(첫 토큰만 빨리 내보냄)
            var pending: [Float] = []       // VAD 판정 대기(256ms 윈도우로 모아 판정)
            var vadState = VadStreamState.initial()   // Silero LSTM 상태(연속 유지 필수)

            for await event in stream {
                guard let self, let manager = self.manager else { break }
                guard case .audio(let samples) = event else { continue }
                pending.append(contentsOf: samples)

                while pending.count >= self.vadWindowSamples {
                    let window = Array(pending.prefix(self.vadWindowSamples))
                    pending.removeFirst(self.vadWindowSamples)

                    // 스트리밍 VAD: 상태를 이어가며 목소리 여부 판정(고립 호출 시 콜드 LSTM이
                    // 가짜 검출하는 문제를 피한다). triggered = Silero 히스테리시스로 안정화된 발화 구간.
                    var voiced = true                  // VAD 미로드 시 fail-open
                    if let vad = self.vad,
                       let r = try? await vad.processStreamingChunk(window, state: vadState) {
                        vadState = r.state
                        voiced = r.state.triggered
                    }

                    if voiced {
                        buffer.append(contentsOf: window)
                        // 첫 인식은 ~0.3초, 이후 ~0.7초, 긴 발화(6초+)는 ~1.2초로 늦춰 CPU 절감.
                        let interval: Int
                        if !firstEmitDone { interval = self.firstTranscribeSamples }
                        else if buffer.count >= self.longBufferSamples { interval = self.longInterval }
                        else { interval = self.transcribeIntervalSamples }
                        if buffer.count - lastCount >= interval {
                            lastCount = buffer.count
                            if let r = await self.transcribe(buffer, manager: manager, boost: false),
                               r.confidence >= self.confidenceThreshold {
                                firstEmitDone = true
                                self.emit(r.text, confirmed: false, confidence: r.confidence)
                            }
                        }
                        if buffer.count >= self.maxUtteranceSamples {
                            if let r = await self.transcribe(buffer, manager: manager, boost: true),
                               r.confidence >= self.confidenceThreshold {
                                self.emit(r.text, confirmed: true, confidence: r.confidence)
                            }
                            buffer.removeAll(keepingCapacity: true); lastCount = 0
                            firstEmitDone = false
                            self.resetLineState()
                        }
                    } else if !buffer.isEmpty {
                        // 발화 종료(VAD가 무음 구간 확인) → 확정 후 비움.
                        if let r = await self.transcribe(buffer, manager: manager, boost: true),
                           r.confidence >= self.confidenceThreshold {
                            self.emit(r.text, confirmed: true, confidence: r.confidence)
                        }
                        buffer.removeAll(keepingCapacity: true); lastCount = 0
                        firstEmitDone = false
                        self.resetLineState()
                    }
                    // buffer 비어있고 목소리도 없으면 버림(무발화 → 자막 없음).
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        // 16kHz 모노로 리샘플만 하고 흘려보낸다. 발화/무음 판정은 소비자 쪽 VAD가 전담.
        guard let feed, let samples = try? converter.resampleBuffer(buffer) else { return }
        feed.yield(.audio(samples))
    }

    func stop() async {
        feed?.finish()
        feed = nil
        consumer?.cancel()
        consumer = nil
        manager = nil
        vad = nil
        spotter = nil
        rescorer = nil
        customVocab = nil
    }

    // MARK: 부스팅 준비

    private func setupBoosting() async {
        do {
            let terms = vocabulary.map { CustomVocabularyTerm(text: $0) }
            let vocab = CustomVocabularyContext(terms: terms, minTermLength: 2)
            let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let spot = CtcKeywordSpotter(models: ctcModels)
            let resc = try await VocabularyRescorer.create(
                spotter: spot,
                vocabulary: vocab,
                ctcModelDirectory: CtcModels.defaultCacheDirectory(for: .ctc110m)
            )
            customVocab = vocab
            spotter = spot
            rescorer = resc
        } catch {
            // 부스팅 비활성(폴백) — 기본 인식만 사용
            customVocab = nil
            spotter = nil
            rescorer = nil
        }
    }

    // MARK: 인식

    private func transcribe(_ samples: [Float], manager: AsrManager, boost: Bool) async -> (text: String, confidence: Double)? {
        guard var state = try? TdtDecoderState(decoderLayers: 2) else { return nil }
        guard let result = try? await manager.transcribe(samples, decoderState: &state) else { return nil }
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 확정 시에만 CustomVocabulary 리스코어링(실패 시 raw 유지).
        if boost,
           let spotter, let rescorer, let customVocab,
           let timings = result.tokenTimings, !timings.isEmpty,
           let spot = try? await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: customVocab),
           !spot.logProbs.isEmpty {
            let output = rescorer.ctcTokenRescore(
                transcript: result.text,
                tokenTimings: timings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration
            )
            let rescored = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rescored.isEmpty { text = rescored }
        }
        return text.isEmpty ? nil : (text, Double(result.confidence))
    }

    private var lastEmittedFull = ""
    private var maxConfirmedLen = 0

    private func emit(_ text: String, confirmed: Bool, confidence: Double) {
        let cc: Int
        if confirmed {
            cc = text.count
        } else {
            // LocalAgreement-2(공통 접두) + 단조 증가(후퇴 안 함) → 앞부터 매끄럽게 흰색.
            let agreed = Self.commonPrefixCount(text, lastEmittedFull)
            lastEmittedFull = text
            maxConfirmedLen = max(maxConfirmedLen, agreed)
            cc = min(maxConfirmedLen, text.count)
        }
        onUpdate?(TranscriptionUpdate(text: text, confirmedCharCount: cc, confidence: confidence))
    }

    private func resetLineState() {       // 발화 종료 시 LocalAgreement/단조 상태 리셋
        lastEmittedFull = ""
        maxConfirmedLen = 0
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
}
