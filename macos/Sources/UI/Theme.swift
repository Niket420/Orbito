import Observation
import SwiftUI

// MARK: - Themes

enum AppTheme: String, CaseIterable, Identifiable {
    case orange
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orange: "Orange & White"
        case .mono: "Black & White"
        }
    }

    var palette: Palette {
        switch self {
        case .orange: .orange
        case .mono: .mono
        }
    }

    var next: AppTheme { self == .orange ? .mono : .orange }
}

/// Every colour the UI uses, by role rather than hue, so each theme can restyle it.
struct Palette {
    let background: Color
    let surface: Color
    let surfaceMuted: Color
    let ink: Color
    let secondaryInk: Color
    let hairline: Color

    let accent: Color
    let accentStrong: Color
    let onAccent: Color
    let gradient: [Color]

    let success: Color
    let warning: Color
    let danger: Color

    let botHead: [Color]
    let botVisor: [Color]
    let botEar: Color
    let eye: Color
    let eyeWaiting: Color
    let eyeDone: Color
    let eyeError: Color
    let confetti: [Color]

    static let orange = Palette(
        background: Color(hex: 0xFFFBF7),
        surface: .white,
        surfaceMuted: Color(hex: 0xFAF6F2),
        ink: Color(hex: 0x1C1917),
        secondaryInk: Color(hex: 0x78716C),
        hairline: Color(hex: 0xF0E9E2),
        accent: Color(hex: 0xF97316),
        accentStrong: Color(hex: 0xEA580C),
        onAccent: .white,
        gradient: [Color(hex: 0xFB923C), Color(hex: 0xF97316), Color(hex: 0xEA580C)],
        success: Color(hex: 0x16A34A),
        warning: Color(hex: 0xB45309),
        danger: Color(hex: 0xDC2626),
        botHead: [Color(hex: 0xFDBA74), Color(hex: 0xF97316), Color(hex: 0xEA580C)],
        botVisor: [Color(hex: 0x1C1917), Color(hex: 0x292524)],
        botEar: Color(hex: 0xEA580C),
        eye: Color(hex: 0xFFF1E6),
        eyeWaiting: Color(hex: 0xFDE68A),
        eyeDone: Color(hex: 0xBBF7D0),
        eyeError: Color(hex: 0xFCA5A5),
        confetti: [Color(hex: 0xF97316), Color(hex: 0xFDBA74), Color(hex: 0x1C1917), Color(hex: 0xFBBF24)]
    )

    static let mono = Palette(
        background: Color(hex: 0xFAFAFA),
        surface: .white,
        surfaceMuted: Color(hex: 0xF4F4F5),
        ink: Color(hex: 0x0A0A0A),
        secondaryInk: Color(hex: 0x71717A),
        hairline: Color(hex: 0xE4E4E7),
        accent: Color(hex: 0x0A0A0A),
        accentStrong: Color(hex: 0x27272A),
        onAccent: .white,
        gradient: [Color(hex: 0x3F3F46), Color(hex: 0x18181B), Color(hex: 0x000000)],
        success: Color(hex: 0x18181B),
        warning: Color(hex: 0x52525B),
        danger: Color(hex: 0xDC2626),
        botHead: [Color(hex: 0x52525B), Color(hex: 0x27272A), Color(hex: 0x09090B)],
        botVisor: [Color(hex: 0x000000), Color(hex: 0x18181B)],
        botEar: Color(hex: 0x18181B),
        eye: .white,
        eyeWaiting: .white,
        eyeDone: .white,
        eyeError: Color(hex: 0xFCA5A5),
        confetti: [Color(hex: 0x0A0A0A), Color(hex: 0x71717A), Color(hex: 0xD4D4D8), Color(hex: 0x3F3F46)]
    )
}

/// The selected theme, persisted across launches. Views that read `Theme.*`
/// in their body update automatically when it changes (Observation tracking).
@Observable
final class ThemeStore: @unchecked Sendable {
    static let shared = ThemeStore()
    private static let key = "appTheme"

    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.key) }
    }

    private init() {
        theme = UserDefaults.standard.string(forKey: Self.key).flatMap(AppTheme.init(rawValue:)) ?? .orange
    }
}

/// Shorthand for the active palette.
enum Theme {
    static var palette: Palette { ThemeStore.shared.theme.palette }

    static var background: Color { palette.background }
    static var card: Color { palette.surface }
    static var surfaceMuted: Color { palette.surfaceMuted }
    static var ink: Color { palette.ink }
    static var secondaryInk: Color { palette.secondaryInk }
    static var hairline: Color { palette.hairline }
    static var accent: Color { palette.accent }
    static var accentStrong: Color { palette.accentStrong }
    static var onAccent: Color { palette.onAccent }
    static var success: Color { palette.success }
    static var warning: Color { palette.warning }
    static var danger: Color { palette.danger }

    static var accentGradient: LinearGradient {
        LinearGradient(colors: palette.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Reusable styles

struct CardBackground: ViewModifier {
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(0.04), radius: 16, y: 6)
            )
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(CardBackground(padding: padding)) }
}

/// Primary filled button with hover lift and press feedback.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverWrapper { hovering in
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(hovering && isEnabled ? Theme.accentStrong : Theme.accent))
                .shadow(color: Theme.accent.opacity(hovering && isEnabled ? 0.30 : 0.15), radius: hovering ? 10 : 6, y: 3)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.35)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

/// Quiet tinted button for secondary actions.
struct SoftButtonStyle: ButtonStyle {
    var tint: Color? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let color = tint ?? Theme.ink
        return HoverWrapper { hovering in
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(color.opacity(hovering ? 0.12 : 0.06)))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

/// Round icon button used in the header.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverWrapper { hovering in
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hovering ? Theme.ink : Theme.secondaryInk)
                .frame(width: 34, height: 34)
                .background(Circle().fill(hovering ? Theme.surfaceMuted : Theme.card))
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

struct HoverWrapper<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}
