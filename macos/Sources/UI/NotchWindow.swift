import AppKit
import SwiftUI

/// Size of the display's camera notch (or a menu-bar-height stand-in on displays without one).
struct NotchMetrics: Equatable {
    /// 0 when the display has no notch.
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    var hasNotch: Bool { notchWidth > 0 }

    static func of(_ screen: NSScreen) -> NotchMetrics {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NotchMetrics(notchWidth: screen.frame.width - left.width - right.width,
                                notchHeight: screen.safeAreaInsets.top)
        }
        return NotchMetrics(notchWidth: 0, notchHeight: NSStatusBar.system.thickness)
    }

    /// The built-in display with a notch if there is one, otherwise the main display.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

/// Borderless, non-activating panel pinned over the notch. It never takes keyboard focus,
/// so the user keeps typing in their own app while Orbito shows its status.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)  // above the menu bar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a button act immediately, even though the panel is never key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the notch panel and keeps it positioned over the notch as displays change.
@MainActor
final class NotchWindowController {
    /// The panel's fixed canvas; the visible notch shape grows inside it.
    static let canvas = CGSize(width: 500, height: 170)

    private let panel = NotchPanel()
    private let assistant: AssistantController
    private var screenObserver: NSObjectProtocol?

    init(assistant: AssistantController) {
        self.assistant = assistant
        layout()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    private func layout() {
        guard let screen = NotchMetrics.preferredScreen() else { return }
        let view = NotchView(metrics: NotchMetrics.of(screen)) { [weak panel] interactive in
            panel?.ignoresMouseEvents = !interactive
        }
        .environment(assistant)
        panel.contentView = FirstMouseHostingView(rootView: view)
        let size = Self.canvas
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }
}
