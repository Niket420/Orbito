import SwiftUI

/// The animated assistant, drawn entirely with SwiftUI shapes in the current theme's colours.
struct AssistantBotView: View {
    let state: AssistantState
    var level: Double = 0

    @State private var shakes: CGFloat = 0

    var body: some View {
        ZStack {
            StateAura(state: state)
                .id(state)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))

            BotFigure(state: state, level: level)
                .modifier(FloatEffect(amplitude: state.floatAmplitude, period: state.floatPeriod))
                .modifier(ShakeEffect(animatableData: shakes))

            StateBadge(state: state)
                .id(state)
                .transition(.scale(scale: 0.2).combined(with: .opacity))
                .offset(x: 76, y: -86)
        }
        .frame(width: 270, height: 270)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: state)
        .onChange(of: state) { _, newValue in
            if newValue == .error {
                withAnimation(.linear(duration: 0.5)) { shakes += 1 }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Assistant")
        .accessibilityValue(state.title)
    }
}

private extension AssistantState {
    var floatAmplitude: CGFloat {
        switch self {
        case .idle: 6
        case .listening, .waitingForApproval: 4
        case .thinking: 5
        case .executing: 2
        case .completed: 7
        case .error: 0
        }
    }

    var floatPeriod: Double { self == .executing ? 0.6 : 2.2 }

    func eyeColor(_ p: Palette) -> Color {
        switch self {
        case .waitingForApproval: p.eyeWaiting
        case .completed: p.eyeDone
        case .error: p.eyeError
        default: p.eye
        }
    }
}

// MARK: - Figure

private struct BotFigure: View {
    let state: AssistantState
    let level: Double
    @State private var blink = false

    var body: some View {
        let p = Theme.palette
        VStack(spacing: -4) {
            Antenna()
            ZStack {
                HStack(spacing: 146) { Ear(); Ear() }
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .fill(LinearGradient(colors: p.botHead, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 156, height: 132)
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.22)).frame(width: 90, height: 12).blur(radius: 2).padding(.top, 9)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: p.accent.opacity(0.22), radius: 20, y: 12)
                visor(p)
            }
        }
        .task(id: state) { await blinkLoop() }
    }

    private func visor(_ p: Palette) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: p.botVisor, startPoint: .top, endPoint: .bottom))
                .frame(width: 120, height: 82)
            BotEyes(state: state, blink: blink, level: level, color: state.eyeColor(p)).offset(y: -8)
            BotMouth(state: state, level: level, color: state.eyeColor(p)).offset(y: 21)
        }
        .offset(y: 4)
    }

    private func blinkLoop() async {
        guard [.idle, .listening, .executing, .thinking].contains(state) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.4...4.8)))
            withAnimation(.easeInOut(duration: 0.07)) { blink = true }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeInOut(duration: 0.09)) { blink = false }
        }
    }
}

private struct Antenna: View {
    @State private var glow = false

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Theme.accentGradient)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                .shadow(color: Theme.accent.opacity(glow ? 0.6 : 0.15), radius: glow ? 10 : 3)
                .scaleEffect(glow ? 1.1 : 1)
            Capsule().fill(Theme.palette.botEar).frame(width: 4, height: 18)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

private struct Ear: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Theme.palette.botEar)
            .frame(width: 14, height: 40)
    }
}

private struct BotEyes: View {
    let state: AssistantState
    let blink: Bool
    let level: Double
    let color: Color

    var body: some View {
        HStack(spacing: 30) {
            eye(left: true)
            eye(left: false)
        }
        .foregroundStyle(color)
        .shadow(color: color.opacity(0.7), radius: 5)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state)
    }

    @ViewBuilder
    private func eye(left: Bool) -> some View {
        Group {
            switch state {
            case .completed:
                HappyArc().stroke(style: StrokeStyle(lineWidth: 5, lineCap: .round)).frame(width: 22, height: 12)
            case .error:
                Capsule().frame(width: 20, height: 6).rotationEffect(.degrees(left ? -14 : 14)).offset(y: 3)
            case .executing:
                Capsule().frame(width: 22, height: 9)
            case .thinking:
                Capsule().frame(width: 15, height: 19).offset(x: 4, y: -5)
            case .listening:
                Circle().frame(width: 20, height: 20).scaleEffect(1 + level * 0.25)
            case .waitingForApproval:
                Circle().frame(width: 22, height: 22)
            case .idle:
                Capsule().frame(width: 16, height: 24)
            }
        }
        .scaleEffect(x: 1, y: blink ? 0.12 : 1)
    }
}

private struct BotMouth: View {
    let state: AssistantState
    let level: Double
    let color: Color

    var body: some View {
        Group {
            switch state {
            case .listening:
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        let base: [CGFloat] = [5, 9, 13, 9, 5]
                        Capsule().frame(width: 4, height: base[i] * (0.5 + CGFloat(level) * 1.6))
                    }
                }
                .frame(height: 22)
                .animation(.easeOut(duration: 0.08), value: level)
            case .completed:
                Smile().stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round)).frame(width: 30, height: 12)
            case .idle:
                Smile().stroke(style: StrokeStyle(lineWidth: 3.5, lineCap: .round)).frame(width: 22, height: 8)
            case .error:
                Smile().stroke(style: StrokeStyle(lineWidth: 3.5, lineCap: .round)).frame(width: 20, height: 7).scaleEffect(y: -1)
            case .thinking:
                Circle().frame(width: 8, height: 8)
            case .waitingForApproval:
                Circle().stroke(lineWidth: 3).frame(width: 11, height: 11)
            case .executing:
                Capsule().frame(width: 18, height: 4)
            }
        }
        .foregroundStyle(color.opacity(0.9))
    }
}

private struct HappyArc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.9))
        return p
    }
}

private struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.9))
        return p
    }
}

// MARK: - Motion

private struct FloatEffect: ViewModifier {
    let amplitude: CGFloat
    let period: Double

    func body(content: Content) -> some View {
        content.phaseAnimator([false, true]) { view, up in
            view.offset(y: up ? -amplitude : amplitude)
        } animation: { _ in
            .easeInOut(duration: period)
        }
    }
}

private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(animatableData * .pi * 6), y: 0))
    }
}

// MARK: - State auras

private struct StateAura: View {
    let state: AssistantState

    var body: some View {
        switch state {
        case .idle:
            Halo(color: Theme.accent)
        case .listening:
            ZStack {
                Halo(color: Theme.accent)
                ForEach(0..<3, id: \.self) { PulseRing(color: Theme.accent, delay: Double($0) * 0.7) }
            }
        case .thinking:
            ZStack {
                Halo(color: Theme.accent)
                OrbitingDots()
            }
        case .executing:
            ZStack {
                Halo(color: Theme.accent)
                SpinningArcs()
            }
        case .waitingForApproval:
            ZStack {
                Halo(color: Theme.warning, period: 0.9)
                PulseRing(color: Theme.warning, delay: 0, duration: 1.4)
            }
        case .completed:
            ZStack {
                Halo(color: Theme.success)
                ConfettiBurst()
            }
        case .error:
            Halo(color: Theme.danger, period: 3)
        }
    }
}

private struct Halo: View {
    let color: Color
    var period: Double = 2.4

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.16), color.opacity(0.06), .clear],
                                 center: .center, startRadius: 10, endRadius: 135))
            .frame(width: 260, height: 260)
            .phaseAnimator([0.92, 1.06]) { view, scale in
                view.scaleEffect(scale)
            } animation: { _ in .easeInOut(duration: period) }
    }
}

private struct PulseRing: View {
    let color: Color
    let delay: Double
    var duration: Double = 2.1
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.45), lineWidth: 2)
            .frame(width: 176, height: 176)
            .scaleEffect(expanded ? 1.5 : 0.9)
            .opacity(expanded ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: duration).repeatForever(autoreverses: false).delay(delay)) {
                    expanded = true
                }
            }
    }
}

private struct OrbitingDots: View {
    @State private var spin = false

    var body: some View {
        let colors = Theme.palette.gradient + [Theme.ink]
        ZStack {
            Circle()
                .stroke(Theme.secondaryInk.opacity(0.25), style: StrokeStyle(lineWidth: 1.2, dash: [3, 7]))
                .frame(width: 230, height: 230)
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(colors[i % colors.count])
                    .frame(width: CGFloat(13 - i * 2), height: CGFloat(13 - i * 2))
                    .offset(y: -115)
                    .rotationEffect(.degrees(Double(i) * 102))
            }
        }
        .rotationEffect(.degrees(spin ? 360 : 0))
        .onAppear {
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

private struct SpinningArcs: View {
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(AngularGradient(colors: [Theme.accent.opacity(0), Theme.accent], center: .center),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 222, height: 222)
                .rotationEffect(.degrees(spin ? 360 : 0))
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(Theme.ink.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 246, height: 246)
                .rotationEffect(.degrees(spin ? -360 : 0))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

private struct ConfettiBurst: View {
    @State private var burst = false

    var body: some View {
        let colors = Theme.palette.confetti
        ZStack {
            Circle()
                .stroke(Theme.success.opacity(0.5), lineWidth: 2.5)
                .frame(width: 168, height: 168)
                .scaleEffect(burst ? 1.6 : 0.8)
                .opacity(burst ? 0 : 1)
            ForEach(0..<16, id: \.self) { i in
                let angle = Double(i) / 16 * 2 * .pi
                RoundedRectangle(cornerRadius: 2)
                    .fill(colors[i % colors.count])
                    .frame(width: 5, height: 11)
                    .rotationEffect(.radians(angle + (burst ? 2 : 0)))
                    .offset(x: cos(angle) * (burst ? 132 : 40), y: sin(angle) * (burst ? 132 : 40))
                    .opacity(burst ? 0 : 1)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2)) { burst = true }
        }
    }
}

// MARK: - Badges

private struct StateBadge: View {
    let state: AssistantState

    var body: some View {
        switch state {
        case .thinking:
            TypingBubble()
        case .waitingForApproval:
            badge("hand.raised.fill", Theme.warning)
                .phaseAnimator([1.0, 1.12]) { view, s in view.scaleEffect(s) } animation: { _ in .easeInOut(duration: 0.6) }
        case .completed:
            badge("checkmark", Theme.success)
        case .error:
            badge("exclamationmark", Theme.danger)
        default:
            EmptyView()
        }
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: color.opacity(0.35), radius: 8, y: 3)
    }
}

private struct TypingBubble: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .phaseAnimator([0.35, 1.0]) { view, o in
                        view.opacity(o).offset(y: o == 1 ? -2 : 1)
                    } animation: { _ in .easeInOut(duration: 0.45).delay(Double(i) * 0.15) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.08), radius: 8, y: 3))
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
    }
}
