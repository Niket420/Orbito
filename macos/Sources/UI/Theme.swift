import SwiftUI

/// Colours, gradients and reusable styles for the white + colourful look.
enum Theme {
    static let blue = Color(red: 0.31, green: 0.49, blue: 1.00)
    static let purple = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)
    static let pink = Color(red: 0.93, green: 0.28, blue: 0.60)
    static let green = Color(red: 0.13, green: 0.77, blue: 0.47)
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let rose = Color(red: 0.96, green: 0.25, blue: 0.37)

    static let background = Color(red: 0.98, green: 0.98, blue: 1.00)
    static let card = Color.white
    static let ink = Color(red: 0.12, green: 0.11, blue: 0.29)
    static let secondaryInk = Color(red: 0.42, green: 0.44, blue: 0.53)
    static let hairline = Color(red: 0.91, green: 0.91, blue: 0.96)

    static let brand = LinearGradient(colors: [blue, purple, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cool = LinearGradient(colors: [cyan, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.card)
                    .shadow(color: Theme.purple.opacity(0.08), radius: 24, y: 10)
                    .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(CardBackground(padding: padding)) }
}

/// Primary gradient capsule button with hover lift and press feedback.
struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverWrapper { hovering in
            configuration.label
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .background(Capsule().fill(Theme.brand))
                .shadow(color: Theme.purple.opacity(hovering && isEnabled ? 0.45 : 0.25), radius: hovering ? 14 : 8, y: 5)
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering && isEnabled ? 1.03 : 1))
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

/// Soft tinted capsule button for secondary actions.
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = Theme.purple
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverWrapper { hovering in
            configuration.label
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(tint.opacity(hovering ? 0.16 : 0.10)))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

/// Round icon button (header settings etc.).
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverWrapper { hovering in
            configuration.label
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hovering ? Theme.purple : Theme.secondaryInk)
                .frame(width: 36, height: 36)
                .background(Circle().fill(hovering ? Theme.purple.opacity(0.10) : Color.white))
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
