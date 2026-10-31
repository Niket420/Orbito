import AVFoundation
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
                @Bindable var shortcut = assistant.shortcut
                Picker("Start Orbito", selection: $shortcut.preset) {
                    ForEach(ShortcutPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Text("Tap both keys: Orbito listens and sends your command when you stop talking. "
                     + "Or hold them while you speak and let go to send.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Then listen for “\(assistant.wakePhrase)”", isOn: $assistant.wakeWordEnabled)
                Text("After the first tap, say “\(assistant.wakePhrase)” to give the next command "
                     + "hands-free. The microphone stays on until you turn this off or quit.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    LabeledContent("Speech", value: providerLabel(health.speechProvider,
                                                                  real: health.speechProvider == "groq-whisper"
                                                                      ? "Groq Whisper (Whistle when offline)"
                                                                      : "Cactus Whistle (on-device)"))
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
