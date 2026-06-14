import Foundation
import ScreenCaptureKit
import AVFAudio
import CoreMedia

/// ScreenCaptureKit으로 특정 앱의 오디오만 캡처한다.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// 캡처된 오디오 버퍼 콜백(버퍼 + PTS). 캡처 큐(백그라운드)에서 호출된다.
    var onBuffer: ((AVAudioPCMBuffer, CMTime) -> Void)?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.sswv.VtuberTranslate.audio")

    enum CaptureError: Error { case noDisplay }

    /// 캡처 가능한 실행 중 앱 목록.
    static func availableApps() async throws -> [SCRunningApplication] {
        let content = try await SCShareableContent.current
        return content.applications
            .filter { !$0.applicationName.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
    }

    func start(app: SCRunningApplication) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // 오디오만 필요하므로 영상은 최소 크기로.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .audio)   // 델리게이트/출력 참조 해제 → 캡처·디코더 즉시 반납
        self.stream = nil
        onBuffer = nil
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = sampleBuffer.toPCMBuffer() else { return }
        onBuffer?(pcm, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

private extension CMSampleBuffer {
    /// 오디오 CMSampleBuffer를 AVAudioPCMBuffer로 변환한다.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }

        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}
