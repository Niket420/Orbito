import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AssistantController.self) private var assistant
    @AppStorage("backendPort") private var port = BackendManager.defaultPort
    @State private var accessibilityTrusted = AccessibilityController.isTrusted
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

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
        .frame(width: 500, height: 620)
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

private struct PermissionBadge: View {
    let granted: Bool

    var body: some View {
        Label(granted ? "Granted" : "Not granted", systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(granted ? Theme.success : Theme.secondaryInk)
    }
}
