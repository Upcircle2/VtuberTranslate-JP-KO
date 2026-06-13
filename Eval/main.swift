import Foundation
import AVFAudio
import CoreMedia

// 자막 파이프라인 오프라인 평가 하니스(.app, LSUIElement).
// `open -a VtuberEval.app --args <audio> <locale> <out-file>` 로 실행(TCC를 위해 LaunchServices 경유).
// 결과는 <out-file>에 기록하고 마지막에 "=== DONE ===" 마커를 남긴다.

let args = CommandLine.arguments
let audioPath = args.count >= 2 ? args[1] : ""
let locale = Locale(identifier: args.count >= 3 ? args[2] : "ja-JP")
let outPath = args.count >= 4 ? args[3] : "/tmp/vtuber_eval_result.txt"

FileManager.default.createFile(atPath: outPath, contents: nil)
let out = FileHandle(forWritingAtPath: outPath)
func log(_ s: String) { out?.write((s + "\n").data(using: .utf8)!) }

/// 인식 업데이트를 수집하고 세그먼트(클리어) 이벤트를 추론한다.
final class Collector {
    private(set) var events: [(t: Double, text: String, cc: Int)] = []
    private(set) var clears = 0
    var firstTokenTime: Double?
    private var start = Date()
    private var prevText = ""
    private let logf: (String) -> Void
    init(_ logf: @escaping (String) -> Void) { self.logf = logf }

    func begin() { start = Date() }
    func record(_ update: TranscriptionUpdate) {
        let t = Date().timeIntervalSince(start)
        if firstTokenTime == nil { firstTokenTime = t }
        if !prevText.isEmpty && update.text.count < prevText.count
            && !update.text.hasPrefix(String(prevText.prefix(min(prevText.count, 4)))) {
            clears += 1
        }
        prevText = update.text
        events.append((t, update.text, update.confirmedCharCount))
        logf("[\(String(format: "%6.2f", t))s] cc=\(update.confirmedCharCount)  \(update.text)")
    }
}

guard !audioPath.isEmpty, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: audioPath)) else {
    log("ERROR: cannot read audio '\(audioPath)'")
    log("=== DONE ===")
    exit(0)
}
let format = file.processingFormat

let collector = Collector(log)
let recognizer = AppleSpeechRecognizer()
let glossary = GlossaryCorrector()
recognizer.onUpdate = { collector.record($0) }

do {
    try await recognizer.start(locale: locale)
} catch {
    log("ERROR: STT start failed: \(error)")
    log("=== DONE ===")
    exit(0)
}

log("--- feeding \(String(format: "%.1f", Double(file.length) / format.sampleRate))s audio (\(Int(format.sampleRate))Hz) ---")
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
log("=== RESULT ===")
log("updates: \(collector.events.count) | line-clears: \(collector.clears)")
if let ft = collector.firstTokenTime { log("latency-to-first-update: \(String(format: "%.2f", ft))s") }
log("final-text: \(finalText)")
log("localized : \(glossary.localize(finalText))")
log("=== DONE ===")
