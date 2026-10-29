import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AssistantController.self) private var assistant
    @AppStorage("backendPort") private var port = BackendManager.defaultPort
    @AppStorage("autoSendShortcut") private var autoSendShortcut = true
    @State private var accessibilityTrusted = AccessibilityController.isTrusted
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        @Bindable var assistant = assistant
        @Bindable var themeStore = ThemeStore.shared
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeStore.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Voice shortcut") {
                let shortcut = assistant.shortcut
                LabeledContent("Hold to talk") {
                    HStack {
                        ShortcutRecorder(shortcut: shortcut)
                        if shortcut.combo != .defaultCombo {
                            Button("Reset") { shortcut.combo = .defaultCombo }
                        }
                    }
                }
                switch shortcut.status {
                case .active:
                    Text("Hold \(shortcut.combo.label) in any app, speak, then let go.")
                        .font(.caption).foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Text(reason).font(.caption).foregroundStyle(Theme.danger)
                }
                Toggle("Send automatically after speaking", isOn: $autoSendShortcut)
                Toggle("Launch Orbito at login", isOn: Binding(get: { launchAtLogin.isOn },
                                                               set: { launchAtLogin.set($0) }))
                if let error = launchAtLogin.error {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                }
            }

            Section("Backend") {
                LabeledContent("Status", value: assistant.backend.connection.label)
                if case .offline(let reason) = assistant.backend.connection {
                    Text(reason).font(.caption).foregroundStyle(Theme.danger)
                }
                if let health = assistant.backend.health {
                    LabeledContent("Planner", value: providerLabel(health.llmProvider,
                                                                   real: health.llmProvider == "groq" ? "Groq" : "AWS Bedrock"))
                    LabeledContent("Speech", value: providerLabel(health.speechProvider, real: "Cactus Whistle (on-device)"))
                }
                LabeledContent("Address", value: assistant.backend.client.baseURL.absoluteString)
                TextField("Port (applies after relaunch)", value: $port, format: .number.grouping(.never))
                LabeledContent("Folder", value: assistant.backend.backendDirectory?.path ?? "Not found")
                HStack {
                    Button("Restart backend") { assistant.backend.restart() }
                    Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.backendLog]) }
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    HStack {
                        PermissionBadge(granted: micStatus == .authorized)
                        if micStatus == .notDetermined {
                            Button("Allow") {
                                Task {
                                    _ = await AudioCapture.requestPermission()
                                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                                }
                            }
                        }
                    }
                }
                LabeledContent("Accessibility (typing & keys)") {
                    HStack {
                        PermissionBadge(granted: accessibilityTrusted)
                        if !accessibilityTrusted {
                            Button("Open Settings") { AccessibilityController.openAccessibilitySettings() }
                        }
                    }
                }
                Text("Permissions are requested only when a feature first needs them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Animation preview") {
                Picker("Bot state", selection: $assistant.previewState) {
                    Text("Live (follow the assistant)").tag(AssistantState?.none)
                    ForEach(AssistantState.allCases) { state in
                        Text(state.previewLabel).tag(AssistantState?.some(state))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 680)
        .tint(Theme.accent)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            accessibilityTrusted = AccessibilityController.isTrusted
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private func providerLabel(_ provider: String, real: String) -> String {
        provider == "mock" ? "Mock (not configured)" : real
    }
}

/// Click, then press the new shortcut. Esc cancels.
private struct ShortcutRecorder: View {
    let shortcut: VoiceShortcut
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(isRecording ? "Press a shortcut…" : shortcut.combo.label) {
                isRecording ? stop() : start()
            }
            .monospaced()
            .help("Click, then press the keys you want to use. Esc cancels.")
            if let rejection {
                Text(rejection).font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        rejection = nil
        isRecording = true
        shortcut.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let combo = KeyCombo(event: event) {
                if let problem = combo.problem {
                    rejection = problem
                } else {
                    shortcut.combo = combo
                    stop()
                }
            }
            return nil  // swallow every key while recording
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        shortcut.resume()
    }
}

/// Wraps the system's login-item registration for this app.
@Observable @MainActor
private final class LaunchAtLogin {
    private(set) var isOn = SMAppService.mainApp.status == .enabled
    private(set) var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Only works for the packaged app (scripts/package.sh), not when run from the terminal."
        }
        isOn = SMAppService.mainApp.status == .enabled
    }
}

private struct PermissionBadge: View {
    let granted: Bool

    var body: some View {
        Label(granted ? "Granted" : "Not granted", systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(granted ? Theme.success : Theme.secondaryInk)
    }
}
