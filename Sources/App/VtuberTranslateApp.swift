import SwiftUI

@main
struct VtuberTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Vtuber 자막 컨트롤", id: "control") {
            ControlView()
                .environmentObject(appDelegate.pipeline)
        }
        .defaultSize(width: 440, height: 420)
        .windowResizability(.contentSize)
    }
}

/// 앱 수명 동안 살아있는 파이프라인을 소유하고, 떠다니는 자막 오버레이 패널을 띄운다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let pipeline = SubtitlePipeline()
    private var overlay: OverlayPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = OverlayPanel(pipeline: pipeline)
        panel.showOnMainScreen()
        overlay = panel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 종료 전에 오디오 캡처·음성 분석기를 비동기로 깔끔히 정리한 뒤 실제로 종료한다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await pipeline.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
