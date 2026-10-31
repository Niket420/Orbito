import SwiftUI

/// What the notch shows, derived from the assistant's state.
enum NotchPhase: Equatable {
    case hidden
    case listening
    case transcribing
    case confirming(String)
    case thinking
    case working(String)
    case approval(ActionDTO)
    case done(String)
    case failed(String)

    static func derive(isRecording: Bool, isTranscribing: Bool, pendingSend: String?,
                       isSubmitting: Bool, task: TaskDTO?, localError: String?) -> NotchPhase {
        if isRecording { return .listening }
        if isTranscribing { return .transcribing }
        if let pendingSend { return .confirming(pendingSend) }
        if isSubmitting { return .thinking }
        if let localError { return .failed(localError) }
        guard let task else { return .hidden }
        switch task.status {
        case .pending:
            return .thinking
        case .running:
            let current = task.actions.first { $0.status != .succeeded }
            return current.map { .working($0.description) } ?? .thinking
        case .waitingForApproval:
            return task.awaitingApproval.map(NotchPhase.approval) ?? .thinking
        case .completed:
            return .done(task.result ?? "Done")
        case .failed:
            return .failed(task.error ?? task.message)
        case .cancelled:
            return .hidden
        }
    }

    /// Phases with buttons; the panel accepts clicks only while one is showing.
    var isInteractive: Bool {
        switch self {
        case .listening, .confirming, .approval: true
        default: false
        }
    }

    /// Finished phases fade back into the notch after a moment.
    var dismissKey: String? {
        switch self {
        case .done(let text): "done:\(text)"
        case .failed(let text): "failed:\(text)"
        default: nil
        }
    }

    /// Extra content under the status row (agent switch, countdown bar or approval buttons).
    var hasExtra: Bool {
        switch self {
        case .listening, .confirming, .approval: true
        default: false
        }
    }
}

enum NotchLayout {
    static let flare: CGFloat = 6
    static let rowHeight: CGFloat = 36
    static let minWidth: CGFloat = 300

    /// Where content starts. The camera notch is solid black hardware, so nothing is
    /// drawn beside or under it; everything sits in rows below it.
    static func contentTop(_ metrics: NotchMetrics) -> CGFloat {
        metrics.hasNotch ? metrics.notchHeight : 0
    }

    /// Size of the black shape (including its top flares) for a phase.
    static func size(for phase: NotchPhase, metrics: NotchMetrics) -> CGSize {
        let width = max(metrics.notchWidth + flare * 2 + 48, minWidth)
        let top = contentTop(metrics)
        switch phase {
        case .hidden:
            return metrics.hasNotch
                ? CGSize(width: metrics.notchWidth + flare * 2, height: metrics.notchHeight)
                : CGSize(width: minWidth * 0.5, height: 0)
        case .listening:
            return CGSize(width: width, height: top + rowHeight + 30)
        case .transcribing, .thinking, .working, .done, .failed:
            return CGSize(width: width, height: top + rowHeight)
        case .confirming:
            return CGSize(width: width, height: top + rowHeight + 10)
        case .approval:
            return CGSize(width: max(width, 360), height: top + rowHeight + 38)
        }
    }
}

/// The black shape that grows out of the notch: square top edge with small outward
/// flares (like the hardware notch), rounded bottom corners.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, bottomRadius) }
        set { flare = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard rect.height > 0, rect.width > flare * 2 else { return p }
        let t = flare
        let b = min(bottomRadius, rect.height / 2, (rect.width - t * 2) / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Orbito's notch: hidden inside the camera notch when idle, growing out of it
/// to show listening, progress, approvals and results.
struct NotchView: View {
    @Environment(AssistantController.self) private var assistant
    let metrics: NotchMetrics
    var onInteractiveChange: (Bool) -> Void = { _ in }
    /// Fixed phase for previews and snapshot checks; nil follows the assistant.
    var phaseOverride: NotchPhase? = nil

    @State private var dismissedKey: String?
    @State private var levels: [CGFloat] = Array(repeating: 0, count: 12)

    private var livePhase: NotchPhase {
        if let phaseOverride { return phaseOverride }
        let live = NotchPhase.derive(isRecording: assistant.isListening, isTranscribing: assistant.isTranscribing,
                                     pendingSend: assistant.pendingAutoSend, isSubmitting: assistant.isSubmitting,
                                     task: assistant.task, localError: assistant.localError)
        // Agent mode is listening again straight away; show each result briefly first.
        if live == .listening, assistant.isAgentMode, let key = finishedPhase.dismissKey, key != dismissedKey {
            return finishedPhase
        }
        return live
    }

    /// The task's own phase, ignoring listening (done/failed when a task has finished).
    private var finishedPhase: NotchPhase {
        NotchPhase.derive(isRecording: false, isTranscribing: false, pendingSend: nil, isSubmitting: false,
                          task: assistant.task, localError: assistant.localError)
    }

    private var phase: NotchPhase {
        let live = livePhase
        return live.dismissKey != nil && live.dismissKey == dismissedKey ? .hidden : live
    }

    /// The black notch hides black accents (Black & White theme), so use white there.
    private var accent: Color { ThemeStore.shared.theme == .mono ? .white : Theme.accent }

    var body: some View {
        let phase = self.phase
        let size = NotchLayout.size(for: phase, metrics: metrics)
        let shape = NotchShape(flare: NotchLayout.flare, bottomRadius: phase == .hidden ? 10 : 18)

        VStack(spacing: 0) {
            content(phase)
                .padding(.horizontal, NotchLayout.flare)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(shape.fill(.black))
                .clipShape(shape)
                .shadow(color: .black.opacity(phase == .hidden ? 0 : 0.25), radius: 10, y: 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: phase)
        .onChange(of: phase.isInteractive, initial: true) { _, interactive in onInteractiveChange(interactive) }
        .onChange(of: finishedPhase.dismissKey) { _, key in
            if key == nil { dismissedKey = nil }
        }
        .task(id: livePhase.dismissKey) { await autoDismiss() }
        .onChange(of: assistant.audioLevel) { _, level in
            levels.removeFirst()
            levels.append(CGFloat(level))
        }
    }

    @ViewBuilder
    private func content(_ phase: NotchPhase) -> some View {
        VStack(spacing: 0) {
            // Behind the camera notch: nothing here would be visible.
            Color.clear.frame(height: NotchLayout.contentTop(metrics))

            if phase != .hidden {
                HStack(spacing: 10) {
                    OrbitoGlyph(size: 14, color: accent, knockout: .black)
                    Text(title(phase)).lineLimit(1).truncationMode(.middle).notchText()
                    Spacer(minLength: 6)
                    trailing(phase)
                }
                .frame(height: NotchLayout.rowHeight)
                .padding(.horizontal, 14)

                if phase.hasExtra {
                    extra(phase)
                        .padding(.horizontal, 14)
                        .transition(.opacity)
                }
            }
        }
        .opacity(phase == .hidden ? 0 : 1)
    }

    private func title(_ phase: NotchPhase) -> String {
        switch phase {
        case .hidden: ""
        case .listening: assistant.isAgentMode ? "Agent mode · listening…" : "Listening…"
        case .transcribing: "Transcribing…"
        case .thinking: "Thinking…"
        case .confirming(let text): "“\(text)”"
        case .working(let step): step
        case .approval(let action): "Allow: \(action.description)?"
        case .done(let result): result
        case .failed(let message): message
        }
    }

    @ViewBuilder
    private func trailing(_ phase: NotchPhase) -> some View {
        switch phase {
        case .hidden:
            EmptyView()
        case .listening:
            Waveform(levels: levels, color: accent)
        case .transcribing, .thinking, .working:
            PulsingDots(color: accent)
        case .confirming:
            Button(action: assistant.cancelPendingSend) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .help("Don't send")
            .accessibilityLabel("Cancel sending")
        case .approval:
            Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(Color(hex: 0xFBBF24))
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Color(hex: 0x22C55E))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 14)).foregroundStyle(Color(hex: 0xF87171))
        }
    }

    @ViewBuilder
    private func extra(_ phase: NotchPhase) -> some View {
        switch phase {
        case .listening:
            HStack(spacing: 8) {
                Text("Agent mode").notchText(opacity: 0.9)
                Text("talk freely, no wake word").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 4)
                Toggle("Agent mode", isOn: Binding(get: { assistant.isAgentMode },
                                                   set: { assistant.setAgentMode($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(accent)
            }
            .frame(height: 26)
        case .confirming:
            SendCountdown(color: accent)
        case .approval:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    let voice = assistant.isListeningForApproval
                    Button { assistant.respondToApproval(false) } label: {
                        Text(voice ? "Deny · say “no”" : "Deny").frame(maxWidth: .infinity, minHeight: 26)
                            .background(Capsule().fill(.white.opacity(0.14)))
                    }
                    Button { assistant.respondToApproval(true) } label: {
                        Text(voice ? "Allow · say “yes”" : "Allow").fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .foregroundStyle(ThemeStore.shared.theme == .mono ? .black : .white)
                            .background(Capsule().fill(accent))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
            }
        default:
            EmptyView()
        }
    }

    private func autoDismiss() async {
        guard let key = livePhase.dismissKey else { return }
        let isFailure = key.hasPrefix("failed:")
        try? await Task.sleep(for: isFailure ? .seconds(4) : .seconds(2.2))
        if !Task.isCancelled { dismissedKey = key }
    }
}

private extension View {
    func notchText(opacity: Double = 1) -> some View {
        font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(opacity))
    }
}

/// Live microphone level bars, newest on the right.
private struct Waveform: View {
    let levels: [CGFloat]
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: 3 + min(1, level) * 15)
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.08), value: levels)
        .accessibilityLabel("Listening")
    }
}

private struct PulsingDots: View {
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .phaseAnimator([0.3, 1.0]) { view, o in view.opacity(o) } animation: { _ in
                        .easeInOut(duration: 0.45).delay(Double(i) * 0.15)
                    }
            }
        }
        .accessibilityLabel("Working")
    }
}

/// A thin bar that drains while a transcript waits to be sent.
private struct SendCountdown: View {
    let color: Color
    @State private var remaining: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(.white.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: geo.size.width * remaining)
                }
        }
        .frame(height: 3)
        .onAppear {
            let seconds = Double(AssistantController.autoSendDelay.components.seconds)
                + Double(AssistantController.autoSendDelay.components.attoseconds) / 1e18
            withAnimation(.linear(duration: seconds)) { remaining = 0 }
        }
    }
}
