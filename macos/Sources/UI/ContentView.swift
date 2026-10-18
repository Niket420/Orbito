import SwiftUI

struct ContentView: View {
    @Environment(AssistantController.self) private var assistant

    var body: some View {
        ZStack {
            BackgroundView()
            VStack(spacing: 0) {
                HeaderView()
                    .padding(.horizontal, 28)
                    .padding(.top, 34)
                GeometryReader { geo in
                    ScrollView {
                        if geo.size.width >= 860 {
                            HStack(alignment: .top, spacing: 28) {
                                AssistantColumn().frame(maxWidth: .infinity)
                                TaskView().frame(width: min(420, geo.size.width * 0.42))
                            }
                            .padding(28)
                        } else {
                            VStack(spacing: 24) {
                                AssistantColumn()
                                TaskView()
                            }
                            .padding(24)
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 680)
        .ignoresSafeArea()
    }
}

// MARK: - Background

private struct BackgroundView: View {
    var body: some View {
        ZStack {
            Theme.background
            glow(Theme.cyan.opacity(0.16), radius: 420, at: .topLeading)
            glow(Theme.purple.opacity(0.11), radius: 380, at: .topTrailing)
            glow(Theme.pink.opacity(0.11), radius: 420, at: .bottomTrailing)
        }
        .ignoresSafeArea()
    }

    /// Soft colour wash; a radial gradient is much cheaper to draw than a large blur.
    private func glow(_ color: Color, radius: CGFloat, at anchor: UnitPoint) -> some View {
        RadialGradient(colors: [color, color.opacity(0)], center: anchor, startRadius: 0, endRadius: radius)
    }
}

// MARK: - Header

private struct HeaderView: View {
    @Environment(AssistantController.self) private var assistant

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.brand).frame(width: 36, height: 36)
                Image(systemName: "waveform").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            }
            .shadow(color: Theme.purple.opacity(0.3), radius: 8, y: 4)
            Text(AppInfo.name)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.ink)

            Spacer()

            if let health = assistant.backend.health {
                if health.llmProvider == "mock" {
                    MockBadge(text: "Mock planner",
                              help: "AWS Bedrock isn't configured, so a simple rule-based planner is used. See README → Bedrock.")
                }
                if health.speechProvider == "mock" {
                    MockBadge(text: "Mock speech",
                              help: "Cactus Whistle isn't installed, so transcription returns a fixed sample sentence.")
                }
            }
            ConnectionPill(connection: assistant.backend.connection)
            SettingsLink {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(IconButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }
}

private struct MockBadge: View {
    let text: String
    let help: String

    var body: some View {
        Label(text, systemImage: "flask.fill")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.amber)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.amber.opacity(0.12)))
            .help(help)
    }
}

private struct ConnectionPill: View {
    let connection: BackendManager.Connection

    private var color: Color {
        switch connection {
        case .connected: Theme.green
        case .connecting: Theme.amber
        case .offline: Theme.rose
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 4))
                .phaseAnimator([1.0, 0.45]) { view, o in
                    view.opacity(connection == .connecting ? o : 1)
                } animation: { _ in .easeInOut(duration: 0.7) }
            Text(connection.label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.white))
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        .animation(.easeInOut, value: connection)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Backend \(connection.label)")
    }

    private var helpText: String {
        if case .offline(let reason) = connection { return reason }
        return "Python backend: \(connection.label)"
    }
}

// MARK: - Assistant + voice

private struct AssistantColumn: View {
    @Environment(AssistantController.self) private var assistant

    var body: some View {
        VStack(spacing: 18) {
            AssistantBotView(state: assistant.state, level: assistant.audioLevel)
                .padding(.top, 4)

            VStack(spacing: 6) {
                Text(assistant.state.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
                Text(assistant.statusDetail)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(assistant.state == .error ? Theme.rose : Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 460)
                    .contentTransition(.opacity)
            }
            .animation(.easeInOut(duration: 0.25), value: assistant.state)
            .animation(.easeInOut(duration: 0.25), value: assistant.statusDetail)

            ComposerCard()
                .frame(maxWidth: 560)
        }
    }
}

private struct ComposerCard: View {
    @Environment(AssistantController.self) private var assistant
    @FocusState private var editorFocused: Bool

    var body: some View {
        @Bindable var assistant = assistant
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Your instruction", systemImage: "text.bubble.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                if assistant.transcriptionProvider == "mock" {
                    Text("Mock transcription")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.amber)
                } else if assistant.transcriptionProvider == "whistle" {
                    Label("Heard by Whistle", systemImage: "waveform")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.blue)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $assistant.draft)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .frame(minHeight: 64, maxHeight: 110)
                    .disabled(assistant.isTaskActive || assistant.isRecording)
                    .accessibilityLabel("Instruction")
                if assistant.draft.isEmpty {
                    Text("Hold the mic and speak, or type something like “Open Safari and search for AI news”")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondaryInk.opacity(0.6))
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.background))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(editorFocused ? Theme.purple.opacity(0.5) : Theme.hairline, lineWidth: editorFocused ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: editorFocused)

            HStack(spacing: 14) {
                MicButton(isRecording: assistant.isRecording,
                          level: assistant.audioLevel,
                          enabled: assistant.canRecord || assistant.isRecording,
                          onPress: assistant.startRecording,
                          onRelease: assistant.stopRecording,
                          onToggle: assistant.toggleRecording)
                VStack(alignment: .leading, spacing: 2) {
                    Text(assistant.isRecording ? "Listening…" : "Hold to talk")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(assistant.isRecording ? Theme.cyan : Theme.ink)
                    Text(assistant.isRecording ? "Release to finish" : "Review the text, then send")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                if assistant.isTaskActive {
                    Button(role: .cancel, action: assistant.cancel) {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .buttonStyle(SoftButtonStyle(tint: Theme.rose))
                    .keyboardShortcut(.escape, modifiers: [])
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button(action: assistant.submit) {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(GradientButtonStyle())
                    .disabled(!assistant.canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (⌘↩)")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: assistant.isTaskActive)
        }
        .card()
    }
}

private struct MicButton: View {
    let isRecording: Bool
    let level: Double
    let enabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    let onToggle: () -> Void

    @State private var pressing = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            if isRecording {
                Circle()
                    .fill(Theme.cyan.opacity(0.18))
                    .scaleEffect(1.15 + level * 0.5)
                Circle()
                    .stroke(Theme.cyan.opacity(0.55), lineWidth: 3)
                    .scaleEffect(1.02 + level * 0.3)
            }
            Circle()
                .fill(isRecording ? Theme.cool : Theme.brand)
                .shadow(color: (isRecording ? Theme.cyan : Theme.purple).opacity(hovering ? 0.55 : 0.35),
                        radius: hovering ? 16 : 10, y: 5)
            Image(systemName: isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: isRecording)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 62, height: 62)
        .padding(6)
        .contentShape(Circle())
        .scaleEffect(pressing ? 0.92 : (hovering && enabled ? 1.05 : 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressing)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.08), value: level)
        .opacity(enabled ? 1 : 0.45)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard enabled, !pressing else { return }
                    pressing = true
                    onPress()
                }
                .onEnded { _ in
                    guard pressing else { return }
                    pressing = false
                    onRelease()
                }
        )
        .onHover { hovering = $0 }
        .help("Hold to talk")
        .accessibilityElement()
        .accessibilityLabel(isRecording ? "Stop listening" : "Start listening")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { onToggle() } }
    }
}
