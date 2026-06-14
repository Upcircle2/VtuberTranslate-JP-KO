import AppKit
import SwiftUI

/// 항상 위에 떠 있는 반투명·비활성 자막 패널. 모든 스페이스/전체화면 위에 표시된다.
final class OverlayPanel: NSPanel {
    init(pipeline: SubtitlePipeline) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        let host = NSHostingView(rootView: SubtitleView().environmentObject(pipeline))
        host.autoresizingMask = [.width, .height]
        if let contentView {
            host.frame = contentView.bounds
            contentView.addSubview(host)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showOnMainScreen() {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let width = min(1200, visible.width - 80)
            let height: CGFloat = 300
            let frame = NSRect(
                x: visible.midX - width / 2,
                y: visible.minY + 80,
                width: width,
                height: height
            )
            setFrame(frame, display: true)
        }
        orderFrontRegardless()
    }
}
