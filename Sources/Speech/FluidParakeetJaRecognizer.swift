import Foundation
import FluidAudio
import AVFAudio
import CoreMedia
import Accelerate

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

    private enum FeedEvent { case audio([Float]); case finalize }
    private var feed: AsyncStream<FeedEvent>.Continuation?
    private var consumer: Task<Void, Never>?

    private let transcribeIntervalSamples = 19_200   // ~1.2초마다 진행 재인식(16kHz 기준)
    private let maxUtteranceSamples = 224_000        // ~14초 안전 상한(모델 윈도우)

    // 라인 클리어용 RMS VAD(append 스레드에서만 접근)
    private let vadSilenceThreshold: Float = 0.008
    private let utteranceResetSeconds = 1.5       // 짧은 쉼엔 안 비우고, 발화 단위로 자연스럽게 끊음
    private var silenceSeconds = 0.0
    private var finalizeArmed = true

    func prewarm(locale: Locale) async {
        _ = try? await AsrModels.downloadAndLoad(version: .tdtJa)
        if !vocabulary.isEmpty {
            _ = try? await CtcModels.downloadAndLoad(variant: .ctc110m)
        }
    }

    func start(locale: Locale) async throws {
        let models = try await AsrModels.downloadAndLoad(version: .tdtJa)
        manager = AsrManager(models: models)
        if !vocabulary.isEmpty { await setupBoosting() }

        silenceSeconds = 0
        finalizeArmed = true

        let (stream, continuation) = AsyncStream<FeedEvent>.makeStream()
        feed = continuation
        consumer = Task { [weak self] in
            var buffer: [Float] = []
            var lastCount = 0
            for await event in stream {
                guard let self, let manager = self.manager else { break }
                switch event {
                case .audio(let samples):
                    buffer.append(contentsOf: samples)
                    if buffer.count - lastCount >= self.transcribeIntervalSamples {
                        lastCount = buffer.count
                        if let text = await self.transcribe(buffer, manager: manager, boost: false) {
                            self.emit(text, confirmed: false)
                        }
                    }
                    if buffer.count >= self.maxUtteranceSamples {
                        if let text = await self.transcribe(buffer, manager: manager, boost: true) {
                            self.emit(text, confirmed: true)
                        }
                        buffer.removeAll(keepingCapacity: true)
                        lastCount = 0
                    }
                case .finalize:
                    if !buffer.isEmpty, let text = await self.transcribe(buffer, manager: manager, boost: true) {
                        self.emit(text, confirmed: true)
                    }
                    buffer.removeAll(keepingCapacity: true)
                    lastCount = 0
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        guard let feed, let samples = try? converter.resampleBuffer(buffer) else { return }
        feed.yield(.audio(samples))

        guard let channels = buffer.floatChannelData else { return }
        var rms: Float = 0
        vDSP_rmsqv(channels[0], 1, &rms, vDSP_Length(buffer.frameLength))
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        if rms < vadSilenceThreshold {
            silenceSeconds += duration
            if silenceSeconds >= utteranceResetSeconds, finalizeArmed {
                finalizeArmed = false
                feed.yield(.finalize)
            }
        } else {
            silenceSeconds = 0
            finalizeArmed = true
        }
    }

    func stop() async {
        feed?.finish()
        feed = nil
        consumer?.cancel()
        consumer = nil
        manager = nil
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

    private func transcribe(_ samples: [Float], manager: AsrManager, boost: Bool) async -> String? {
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
        return text.isEmpty ? nil : text
    }

    private func emit(_ text: String, confirmed: Bool) {
        onUpdate?(TranscriptionUpdate(text: text, confirmedCharCount: confirmed ? text.count : 0))
    }
}
