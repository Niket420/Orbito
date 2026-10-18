import AppKit

/// Observes which app is in front, so actions can be verified and input goes to the right app.
@MainActor
final class ScreenObserver {
    /// The most recent frontmost app other than Whisper itself.
    private(set) var lastExternalApp: NSRunningApplication?
    private var token: NSObjectProtocol?

    init() {
        lastExternalApp = Self.isSelf(NSWorkspace.shared.frontmostApplication) ? nil : NSWorkspace.shared.frontmostApplication
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, !Self.isSelf(app) { self?.lastExternalApp = app }
            }
        }
    }

    var frontmostApp: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }
    var isSelfFrontmost: Bool { NSRunningApplication.current.isActive }

    func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// A short description of what's in front, used as an action observation.
    func describeFront() -> String {
        guard let app = frontmostApp else { return "No app is in front" }
        let name = app.localizedName ?? "An app"
        if let title = AccessibilityController.focusedWindowTitle(of: app.processIdentifier), !title.isEmpty {
            return "\(name) is in front (window: \(title.prefix(80)))"
        }
        return "\(name) is in front"
    }

    /// Polls `condition` every 100 ms until it's true or the timeout passes.
    func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func isSelf(_ app: NSRunningApplication?) -> Bool {
        app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}
