import CoreGraphics
import Foundation

/// Keyboard simulation, used only for approved `type_text` / `press_key` actions.
enum InputController {
    /// ANSI virtual key codes (Carbon kVK_*) for the allowlisted keys.
    static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    static let modifierFlags: [String: CGEventFlags] = [
        "command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl,
    ]

    /// Types text into the focused element in small Unicode chunks.
    static func type(_ text: String) async {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            let chunk = Array(units[start..<min(start + 16, units.count)])
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    /// Presses a key with optional modifiers. Returns false for unknown keys.
    static func press(key: String, modifiers: [String]) -> Bool {
        guard let code = keyCodes[key] else { return false }
        let flags = modifiers.reduce(into: CGEventFlags()) { $0.insert(modifierFlags[$1] ?? []) }
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        return true
    }
}
