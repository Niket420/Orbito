import AppKit
import SwiftUI

enum AppInfo {
    /// The assistant's display name. Change it here to rename the app's UI.
    static let name = "Orbito"
}

@main
struct VoiceAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `Orbito --export-iconset <dir>` renders the app icon for scripts/package.sh, then exits.
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--export-iconset"), args.indices.contains(flag + 1) {
            do {
                try OrbitoIcon.exportIconset(to: URL(fileURLWithPath: args[flag + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Icon export failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            ContentView()
                .environment(appDelegate.controller)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 720)

        Settings {
            SettingsView()
                .environment(appDelegate.controller)
                .preferredColorScheme(.light)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AssistantController()
    private var signalSources: [DispatchSourceSignal] = []
    private var notch: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable rather than a .app bundle.
        NSApp.setActivationPolicy(.regular)
        // Dock icon when run unbundled (`swift run`); the .app also ships AppIcon.icns.
        NSApp.applicationIconImage = OrbitoIcon.image(pixels: 512)
        NSApp.activate(ignoringOtherApps: true)
        installTerminationSignalHandlers()
        controller.backend.start()

        // Hold-to-talk from anywhere, with status shown in the notch.
        controller.shortcut.onPress = { [weak controller] in controller?.shortcutPressed() }
        controller.shortcut.onRelease = { [weak controller] in controller?.shortcutReleased() }
        controller.shortcut.register()
        notch = NotchWindowController(assistant: controller)
        notch?.show()
    }

    /// Treat SIGTERM/SIGINT (e.g. `kill`, Ctrl-C in a terminal) as a normal quit so the backend is stopped.
    private func installTerminationSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.backend.stop()
    }

    /// Keep running in the notch after the window closes; quit with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
