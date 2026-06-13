import Foundation
import AVFAudio
import CoreMedia
import Translation

// 자막 파이프라인 오프라인 평가 하니스(.app, LSUIElement).
// `open -a VtuberEval.app --args <audio> <locale> <out-file>` (TCC 위해 LaunchServices 경유).
// 측정: 지연(첫토큰/첫확정), 매끄러움(flicker=확정 후퇴), 세그먼트(clears), 번역 결과/소요.

func fmt(_ t: Double) -> String { String(format: "%6.2f", t) }

final class Collector {
    private(set) var events: [(t: Double, text: String, cc: Int)] = []
    private(set) var clears = 0      // 새 발화(라인 비움) — 정상
    private(set) var flickers = 0    // 확정 후퇴(흰→회) — 매끄러움 저하(낮을수록 좋음)
    var firstTokenTime: Double?
    var firstConfirmedTime: Double?
    private var start = Date()
    private var prevText = ""
    private var prevCC = 0
    private let logf: (String) -> Void
    init(_ logf: @escaping (String) -> Void) { self.logf = logf }

    func begin() { start = Date() }
    func record(_ u: TranscriptionUpdate) {
        let t = Date().timeIntervalSince(start)
        if firstTokenTime == nil { firstTokenTime = t }
        if firstConfirmedTime == nil, u.confirmedCharCount > 0 { firstConfirmedTime = t }
        if !prevText.isEmpty {
            if u.text.count < prevText.count / 2 {
                clears += 1                              // 새 발화로 라인 비움
            } else if u.confirmedCharCount < prevCC {
                flickers += 1                            // 확정 후퇴 = 깜빡임
            }
        }
        prevText = u.text; prevCC = u.confirmedCharCount
        minConfidence = min(minConfidence, u.confidence)
        events.append((t, u.text, u.confirmedCharCount))
        logf("[\(fmt(t))s] cc=\(u.confirmedCharCount) conf=\(String(format: "%.2f", u.confidence))  \(u.text)")
    }
    private(set) var minConfidence = 1.0
}

let args = CommandLine.arguments
let audioPath = args.count >= 2 ? args[1] : ""
let localeId = args.count >= 3 ? args[2] : "ja-JP"
let locale = Locale(identifier: localeId)
let outPath = args.count >= 4 ? args[3] : "/tmp/vtuber_eval_result.txt"

FileManager.default.createFile(atPath: outPath, contents: nil)
let out = FileHandle(forWritingAtPath: outPath)
func log(_ s: String) { out?.write((s + "\n").data(using: .utf8)!) }

guard !audioPath.isEmpty, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: audioPath)) else {
    log("ERROR: cannot read audio '\(audioPath)'"); log("=== DONE ==="); exit(0)
}
let format = file.processingFormat

let engineArg = args.count >= 5 ? args[4] : "apple"
let collector = Collector(log)
let glossary = GlossaryCorrector()
let recognizer: SpeechRecognizing = (engineArg == "parakeet") ? FluidParakeetJaRecognizer() : AppleSpeechRecognizer()
log("--- engine: \(engineArg) ---")
recognizer.onUpdate = { collector.record($0) }

do { try await recognizer.start(locale: locale) }
catch { log("ERROR: STT start failed: \(error)"); log("=== DONE ==="); exit(0) }

log("--- feeding \(String(format: "%.1f", Double(file.length) / format.sampleRate))s audio ---")
collector.begin()

let chunkFrames = AVAudioFrameCount(format.sampleRate * 0.1)
var pts = CMTime.zero
while file.framePosition < file.length {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
    do { try file.read(into: buffer, frameCount: chunkFrames) } catch { break }
    if buffer.frameLength == 0 { break }
    recognizer.append(buffer, at: pts)
    let dur = Double(buffer.frameLength) / format.sampleRate
    pts = CMTimeAdd(pts, CMTime(seconds: dur, preferredTimescale: 48_000))
    try? await Task.sleep(for: .seconds(dur))
}
try? await Task.sleep(for: .seconds(2.5))
await recognizer.stop()
try? await Task.sleep(for: .milliseconds(200))

let finalText = collector.events.last?.text ?? ""
let localizedFinal = glossary.localize(finalText)

log("=== RESULT ===")
log("updates: \(collector.events.count) | clears: \(collector.clears) | flickers: \(collector.flickers) | min-conf: \(String(format: "%.2f", collector.minConfidence))")
if let ft = collector.firstTokenTime { log("latency-first-token: \(String(format: "%.2f", ft))s") }
if let fc = collector.firstConfirmedTime { log("latency-first-confirmed: \(String(format: "%.2f", fc))s") }
log("final-text: \(finalText)")
log("localized : \(localizedFinal)")

// 번역(헤드리스 세션) + 소요 측정
do {
    let langCode = locale.language.languageCode?.identifier ?? "ja"
    let session = TranslationSession(
        installedSource: Locale.Language(identifier: langCode),
        target: Locale.Language(identifier: "ko"))
    let tStart = Date()
    let response = try await session.translate(localizedFinal)
    let tMs = Int(Date().timeIntervalSince(tStart) * 1000)
    let korean = ConversationalStyle.casualize(response.targetText)
    log("korean    : \(korean)")
    log("translate-ms: \(tMs)")
} catch {
    log("korean    : (번역 세션 실패: \(error))")
}
log("=== DONE ===")
