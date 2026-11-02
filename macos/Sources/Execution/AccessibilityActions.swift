import AppKit
import ApplicationServices

/// Window control, clicking by name and reading text, via the Accessibility API.
/// All of these act on the frontmost app and need Accessibility permission.
extension AccessibilityController {
    // MARK: - Windows

    enum WindowError: LocalizedError {
        case noWindow, unsupported(String)
        var errorDescription: String? {
            switch self {
            case .noWindow: "The app in front has no window I can control."
            case .unsupported(let what): "This window can't be \(what)."
            }
        }
    }

    /// Applies a window operation to the frontmost app's focused window.
    static func controlFrontWindow(_ operation: String) throws {
        guard let window = frontWindow() else { throw WindowError.noWindow }
        switch operation {
        case "minimize":
            guard set(window, kAXMinimizedAttribute, kCFBooleanTrue) else { throw WindowError.unsupported("minimized") }
        case "fullscreen":
            let isFull = (value(window, "AXFullScreen") as? Bool) ?? false
            guard set(window, "AXFullScreen", isFull ? kCFBooleanFalse : kCFBooleanTrue) else {
                throw WindowError.unsupported("made full screen")
            }
        case "close":
            guard let button = element(window, kAXCloseButtonAttribute),
                  AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                throw WindowError.unsupported("closed")
            }
        default:
            guard let frame = frame(of: window) else { throw WindowError.noWindow }
            let screens = NSScreen.screens.map { axFrame(of: $0) }
            let current = screens.firstIndex { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? 0
            let screen = screens.isEmpty ? frame : screens[current]
            let target: CGRect
            switch operation {
            case "maximize": target = screen
            case "left_half": target = CGRect(x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
            case "right_half": target = CGRect(x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height)
            case "top_half": target = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height / 2)
            case "bottom_half": target = CGRect(x: screen.minX, y: screen.midY, width: screen.width, height: screen.height / 2)
            case "center":
                target = CGRect(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2,
                                width: frame.width, height: frame.height)
            case "next_display":
                guard screens.count > 1 else { throw WindowError.unsupported("moved: there's only one display") }
                let next = screens[(current + 1) % screens.count]
                target = CGRect(x: next.minX + (frame.minX - screen.minX), y: next.minY + (frame.minY - screen.minY),
                                width: min(frame.width, next.width), height: min(frame.height, next.height))
            default: throw WindowError.unsupported(operation)
            }
            guard setFrame(window, target) else { throw WindowError.unsupported("moved or resized") }
        }
    }

    /// A screen's usable area (without menu bar and Dock) in Accessibility coordinates
    /// (origin at the top-left of the main display).
    static func axFrame(of screen: NSScreen) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: mainHeight - visible.maxY, width: visible.width, height: visible.height)
    }

    // MARK: - Clicking

    static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXTab",
        "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle", "AXCell", "AXRow", "AXStaticText", "AXImage",
    ]

    /// Clicks the element in the front app whose label best matches `target`:
    /// an exact label first, then one that starts with it, then one that contains it.
    /// Returns the label that was clicked.
    static func click(_ target: String) -> String? {
        guard let app = frontAppElement() else { return nil }
        let wanted = normalize(target)
        var best: (element: AXUIElement, label: String, score: Int)?
        let roots = [element(app, kAXFocusedWindowAttribute), element(app, kAXMenuBarAttribute)].compactMap { $0 }
        for root in roots {
            walk(root, limit: 4000) { node, role in
                guard clickableRoles.contains(role), let label = label(of: node) else { return false }
                let name = normalize(label)
                let score = name == wanted ? 3 : name.hasPrefix(wanted) ? 2 : name.contains(wanted) ? 1 : 0
                if score > (best?.score ?? 0) || (score > 0 && score == best?.score && role != "AXStaticText"
                                                   && label.count < best!.label.count) {
                    best = (node, label, score)
                }
                return score == 3 && role != "AXStaticText"  // stop at an exact match on a real control
            }
        }
        guard let best else { return nil }
        if AXUIElementPerformAction(best.element, kAXPressAction as CFString) == .success { return best.label }
        // Elements without a press action (some web content, text): click their centre.
        guard let frame = frame(of: best.element) else { return nil }
        InputController.click(at: CGPoint(x: frame.midX, y: frame.midY))
        return best.label
    }

    // MARK: - Reading

    /// The text visible in the front app's focused window, in reading order, de-duplicated.
    static func visibleText(limit: Int = 8000) -> String {
        guard let app = frontAppElement(), let window = element(app, kAXFocusedWindowAttribute) else { return "" }
        var lines: [String] = []
        var seen = Set<String>()
        var total = 0
        walk(window, limit: 6000) { node, role in
            guard ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXButton", "AXCell"]
                .contains(role) else { return false }
            let text = ((value(node, kAXValueAttribute) as? String) ?? label(of: node) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 1, seen.insert(text).inserted else { return false }
            lines.append(text)
            total += text.count + 1
            return total >= limit
        }
        let title = (value(window, kAXTitleAttribute) as? String).map { "Window: \($0)\n" } ?? ""
        return String((title + lines.joined(separator: "\n")).prefix(limit))
    }

    /// The text selected in the focused element, if the app exposes it.
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        guard let focused = element(system, kAXFocusedUIElementAttribute),
              let text = value(focused, kAXSelectedTextAttribute) as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: - Helpers

    private static func frontAppElement() -> AXUIElement? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        // Chrome, Electron apps and others only build their web content tree when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return app
    }

    private static func frontWindow() -> AXUIElement? {
        frontAppElement().flatMap { element($0, kAXFocusedWindowAttribute) }
    }

    /// Depth-first walk; `visit` returns true to stop early.
    private static func walk(_ root: AXUIElement, limit: Int, visit: (AXUIElement, String) -> Bool) {
        var stack = [root]
        var count = 0
        while let node = stack.popLast(), count < limit {
            count += 1
            let role = value(node, kAXRoleAttribute) as? String ?? ""
            if visit(node, role) { return }
            if let children = value(node, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
    }

    private static func label(of node: AXUIElement) -> String? {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
            if let text = value(node, name) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        if let titleElement = element(node, kAXTitleUIElementAttribute) {
            return value(titleElement, kAXValueAttribute) as? String
        }
        return nil
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    private static func frame(of node: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = value(node, kAXPositionAttribute), let extent = value(node, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),  // swiftlint:disable:this force_cast
              AXValueGetValue(extent as! AXValue, .cgSize, &size) else { return nil }  // swiftlint:disable:this force_cast
        return CGRect(origin: origin, size: size)
    }

    private static func setFrame(_ window: AXUIElement, _ frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return false }
        // Size, move, then size again: moving between displays can clamp the first resize.
        _ = set(window, kAXSizeAttribute, extent)
        let moved = set(window, kAXPositionAttribute, position)
        let sized = set(window, kAXSizeAttribute, extent)
        return moved || sized
    }

    private static func value(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = value(node, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)  // swiftlint:disable:this force_cast
    }

    @discardableResult
    private static func set(_ node: AXUIElement, _ name: String, _ newValue: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(node, name as CFString, newValue) == .success
    }
}
