import SwiftUI

struct ContentView: View {
    @Environment(AssistantController.self) private var assistant
    private let themeStore = ThemeStore.shared

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
        .tint(Theme.accent)
        // Rebuild the view tree on theme change so every colour (including ones
        // captured in running animations) picks up the new palette.
        .id(themeStore.theme)
        .animation(.easeInOut(duration: 0.25), value: themeStore.theme)
        .onChange(of: themeStore.theme, initial: true) { _, theme in
            NSApp.applicationIconImage = OrbitoIcon.image(pixels: 512, theme: theme)
        }
    }
}

// MARK: - Background

private struct BackgroundView: View {
    var body: some View {
        // Plain on purpose: the logo's knockout gaps are drawn in this exact colour.
        Theme.background
            .ignoresSafeArea()
    }
}

// MARK: - Header

private struct HeaderView: View {
    @Environment(AssistantController.self) private var assistant

    var body: some View {
        HStack(spacing: 10) {
            OrbitoLockup()

            Spacer()

            if let health = assistant.backend.health {
                if health.llmProvider == "mock" {
                    MockBadge(text: "Mock planner",
                              help: "No LLM is configured, so a simple rule-based planner is used. See README → Configuring the planner.")
                }
                if health.speechProvider == "mock" {
                    MockBadge(text: "Mock speech",
                              help: "Cactus Whistle isn't installed, so transcription returns a fixed sample sentence.")
                }
            }
            ConnectionPill(connection: assistant.backend.connection)
            ThemeSwitcher()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }
}

/// Two swatches in a capsule; click one to switch theme.
struct ThemeSwitcher: View {
    private let store = ThemeStore.shared

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTheme.allCases) { theme in
                Button {
                    store.theme = theme
                } label: {
                    Swatch(theme: theme, selected: store.theme == theme)
                }
                .buttonStyle(.plain)
                .help(theme.title)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(store.theme == theme ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
    }

    private struct Swatch: View {
        let theme: AppTheme
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            let p = theme.palette
            ZStack {
                Circle().fill(.white)
                Circle()
                    .trim(from: 0, to: 0.5)
                    .fill(p.accent)
                    .rotationEffect(.degrees(-45))
            }
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
            .padding(3)
            .overlay(Circle().stroke(selected ? Theme.ink : .clear, lineWidth: 1.5))
            .scaleEffect(hovering && !selected ? 1.08 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
        }
    }
}

private struct MockBadge: View {
    let text: String
    let help: String

    var body: some View {
        Label(text, systemImage: "flask")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.warning.opacity(0.10)))
            .help(help)
    }
}

private struct ConnectionPill: View {
    let connection: BackendManager.Connection

    private var color: Color {
        switch connection {
        case .connected: Color(hex: 0x16A34A)
        case .connecting: Color(hex: 0xF59E0B)
        case .offline: Theme.danger
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .phaseAnimator([1.0, 0.4]) { view, o in
                    view.opacity(connection == .connecting ? o : 1)
                } animation: { _ in .easeInOut(duration: 0.7) }
            Text(connection.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.card))
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
        VStack(spacing: 16) {
            AssistantBotView(state: assistant.state, level: assistant.audioLevel)
                .padding(.top, 4)

            VStack(spacing: 6) {
                Text(assistant.state.title)
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
                Text(assistant.statusDetail)
                    .font(.system(size: 14))
                    .foregroundStyle(assistant.state == .error ? Theme.danger : Theme.secondaryInk)
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
                Text("INSTRUCTION")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                if assistant.transcriptionProvider == "mock" {
                    Text("Mock transcription")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.warning)
                } else if assistant.transcriptionProvider == "whistle" {
                    Label("Transcribed on-device", systemImage: "waveform")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondaryInk)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $assistant.draft)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .frame(minHeight: 64, maxHeight: 110)
                    .disabled(assistant.isTaskActive || assistant.isRecording)
                    .accessibilityLabel("Instruction")
                if assistant.draft.isEmpty {
                    Text("Hold the mic and speak, or type something like “Open Safari and search for AI news”")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryInk.opacity(0.7))
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceMuted))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(editorFocused ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: editorFocused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: editorFocused)

            HStack(spacing: 14) {
                MicButton(isRecording: assistant.isRecording,
                          level: assistant.audioLevel,
                          enabled: assistant.canRecord || assistant.isRecording,
                          onPress: assistant.startRecording,
                          onRelease: { assistant.stopRecording() },
                          onToggle: assistant.toggleRecording)
                VStack(alignment: .leading, spacing: 2) {
                    Text(assistant.isRecording ? "Listening…" : "Hold to talk")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(assistant.isRecording ? Theme.accent : Theme.ink)
                    Text(assistant.isRecording ? "Release to finish"
                         : assistant.shortcut.isActive ? "Or hold \(assistant.shortcut.combo.label) anywhere"
                         : "Review the text, then send")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                if assistant.isTaskActive {
                    Button(role: .cancel, action: assistant.cancel) {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .buttonStyle(SoftButtonStyle(tint: Theme.danger))
                    .keyboardShortcut(.escape, modifiers: [])
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Button(action: assistant.submit) {
                        Label("Send", systemImage: "arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
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
                    .fill(Theme.accent.opacity(0.12))
                    .scaleEffect(1.15 + level * 0.5)
                Circle()
                    .stroke(Theme.accent.opacity(0.45), lineWidth: 2)
                    .scaleEffect(1.02 + level * 0.3)
            }
            Circle()
                .fill(hovering && enabled ? Theme.accentStrong : Theme.accent)
                .shadow(color: Theme.accent.opacity(hovering ? 0.35 : 0.2), radius: hovering ? 12 : 8, y: 4)
            Image(systemName: isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .symbolEffect(.variableColor.iterative, isActive: isRecording)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 58, height: 58)
        .padding(6)
        .contentShape(Circle())
        .scaleEffect(pressing ? 0.92 : (hovering && enabled ? 1.04 : 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressing)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.08), value: level)
        .opacity(enabled ? 1 : 0.4)
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
