import SwiftUI

/// The colourful animated assistant, drawn entirely with SwiftUI shapes.
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
                .offset(x: 78, y: -88)
        }
        .frame(width: 280, height: 280)
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
        case .idle: 7
        case .listening, .waitingForApproval: 4
        case .thinking: 5
        case .executing: 2
        case .completed: 8
        case .error: 0
        }
    }

    var floatPeriod: Double { self == .executing ? 0.6 : 2.2 }

    var eyeColor: Color {
        switch self {
        case .waitingForApproval: Theme.amber
        case .completed: Color(red: 0.55, green: 1.0, blue: 0.80)
        case .error: Color(red: 1.0, green: 0.55, blue: 0.62)
        default: Color(red: 0.62, green: 0.96, blue: 1.0)
        }
    }

    var headColors: [Color] {
        switch self {
        case .waitingForApproval: [Theme.amber, Theme.pink, Theme.purple]
        case .completed: [Theme.cyan, Theme.blue, Theme.purple]
        case .error: [Theme.pink, Theme.rose, Theme.purple]
        case .listening: [Theme.cyan, Theme.blue, Theme.purple]
        default: [Theme.blue, Theme.purple, Theme.pink]
        }
    }
}

// MARK: - Figure

private struct BotFigure: View {
    let state: AssistantState
    let level: Double
    @State private var blink = false

    var body: some View {
        VStack(spacing: -4) {
            Antenna(state: state)
            ZStack {
                HStack(spacing: 148) { Ear(); Ear() }
                head
                visor
            }
        }
        .task(id: state) { await blinkLoop() }
    }

    private var head: some View {
        RoundedRectangle(cornerRadius: 46, style: .continuous)
            .fill(LinearGradient(colors: state.headColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 160, height: 136)
            .overlay(alignment: .top) {
                Capsule().fill(.white.opacity(0.28)).frame(width: 96, height: 16).blur(radius: 2).padding(.top, 9)
            }
            .overlay(RoundedRectangle(cornerRadius: 46, style: .continuous).stroke(.white.opacity(0.45), lineWidth: 1.5))
            .shadow(color: state.headColors[1].opacity(0.35), radius: 22, y: 12)
    }

    private var visor: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.11, green: 0.10, blue: 0.27), Color(red: 0.19, green: 0.16, blue: 0.45)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 124, height: 86)
            HStack(spacing: 58) {
                Circle().fill(Theme.pink.opacity(0.45)).frame(width: 12, height: 12).blur(radius: 2)
                Circle().fill(Theme.pink.opacity(0.45)).frame(width: 12, height: 12).blur(radius: 2)
            }
            .offset(y: 18)
            BotEyes(state: state, blink: blink, level: level).offset(y: -9)
            BotMouth(state: state, level: level).offset(y: 22)
        }
        .offset(y: 4)
    }

    private func blinkLoop() async {
        guard state == .idle || state == .listening || state == .executing || state == .thinking else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.4...4.8)))
            withAnimation(.easeInOut(duration: 0.07)) { blink = true }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeInOut(duration: 0.09)) { blink = false }
        }
    }
}

private struct Antenna: View {
    let state: AssistantState
    @State private var glow = false

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(LinearGradient(colors: [Theme.cyan, Theme.blue], startPoint: .top, endPoint: .bottom))
                .frame(width: 18, height: 18)
                .overlay(Circle().fill(.white.opacity(0.7)).frame(width: 6, height: 6).offset(x: -3, y: -3))
                .shadow(color: Theme.cyan.opacity(glow ? 0.9 : 0.3), radius: glow ? 12 : 4)
                .scaleEffect(glow ? 1.12 : 1)
            Capsule().fill(Theme.purple.opacity(0.85)).frame(width: 5, height: 20)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

private struct Ear: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [Theme.purple, Theme.blue], startPoint: .top, endPoint: .bottom))
            .frame(width: 16, height: 44)
    }
}

private struct BotEyes: View {
    let state: AssistantState
    let blink: Bool
    let level: Double

    var body: some View {
        HStack(spacing: 30) {
            eye(left: true)
            eye(left: false)
        }
        .foregroundStyle(state.eyeColor)
        .shadow(color: state.eyeColor.opacity(0.9), radius: 6)
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
        .foregroundStyle(state.eyeColor.opacity(0.9))
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
            Halo(colors: [Theme.blue, Theme.purple])
        case .listening:
            ZStack {
                Halo(colors: [Theme.cyan, Theme.blue])
                ForEach(0..<3, id: \.self) { PulseRing(color: Theme.cyan, delay: Double($0) * 0.7) }
            }
        case .thinking:
            ZStack {
                Halo(colors: [Theme.purple, Theme.pink])
                OrbitingDots()
            }
        case .executing:
            ZStack {
                Halo(colors: [Theme.blue, Theme.cyan])
                SpinningArcs()
            }
        case .waitingForApproval:
            ZStack {
                Halo(colors: [Theme.amber, Theme.pink], period: 0.9)
                PulseRing(color: Theme.amber, delay: 0, duration: 1.4)
            }
        case .completed:
            ZStack {
                Halo(colors: [Theme.green, Theme.cyan])
                ConfettiBurst()
            }
        case .error:
            Halo(colors: [Theme.rose, Theme.pink], period: 3)
        }
    }
}

private struct Halo: View {
    let colors: [Color]
    var period: Double = 2.4

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [colors[0].opacity(0.32), colors[1].opacity(0.16), .clear],
                                 center: .center, startRadius: 10, endRadius: 140))
            .frame(width: 270, height: 270)
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
            .stroke(color.opacity(0.65), lineWidth: 2.5)
            .frame(width: 180, height: 180)
            .scaleEffect(expanded ? 1.55 : 0.9)
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
    private let colors = [Theme.blue, Theme.purple, Theme.pink, Theme.cyan]

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.purple.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [4, 7]))
                .frame(width: 236, height: 236)
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(colors[i])
                    .frame(width: CGFloat(16 - i * 2), height: CGFloat(16 - i * 2))
                    .shadow(color: colors[i].opacity(0.8), radius: 6)
                    .offset(y: -118)
                    .rotationEffect(.degrees(Double(i) * 90 + Double(i) * 12))
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
                .stroke(AngularGradient(colors: [Theme.cyan.opacity(0), Theme.cyan, Theme.blue, Theme.purple], center: .center),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: 226, height: 226)
                .rotationEffect(.degrees(spin ? 360 : 0))
            Circle()
                .trim(from: 0, to: 0.35)
                .stroke(Theme.pink.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 250, height: 250)
                .rotationEffect(.degrees(spin ? -360 : 0))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

private struct ConfettiBurst: View {
    @State private var burst = false
    private let colors = [Theme.blue, Theme.purple, Theme.pink, Theme.cyan, Theme.green, Theme.amber]

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.green.opacity(0.6), lineWidth: 3)
                .frame(width: 170, height: 170)
                .scaleEffect(burst ? 1.6 : 0.8)
                .opacity(burst ? 0 : 1)
            ForEach(0..<16, id: \.self) { i in
                let angle = Double(i) / 16 * 2 * .pi
                RoundedRectangle(cornerRadius: 2)
                    .fill(colors[i % colors.count])
                    .frame(width: 6, height: 12)
                    .rotationEffect(.radians(angle + (burst ? 2 : 0)))
                    .offset(x: cos(angle) * (burst ? 135 : 40), y: sin(angle) * (burst ? 135 : 40))
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
            badge("hand.raised.fill", Theme.amber)
                .phaseAnimator([1.0, 1.15]) { view, s in view.scaleEffect(s) } animation: { _ in .easeInOut(duration: 0.6) }
        case .completed:
            badge("checkmark", Theme.green)
        case .error:
            badge("exclamationmark", Theme.rose)
        default:
            EmptyView()
        }
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: color.opacity(0.5), radius: 10, y: 4)
    }
}

private struct TypingBubble: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.purple)
                    .frame(width: 7, height: 7)
                    .phaseAnimator([0.35, 1.0]) { view, o in
                        view.opacity(o).offset(y: o == 1 ? -2 : 1)
                    } animation: { _ in .easeInOut(duration: 0.45).delay(Double(i) * 0.15) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Capsule().fill(.white).shadow(color: Theme.purple.opacity(0.2), radius: 8, y: 3))
    }
}
