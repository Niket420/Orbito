import AppKit
import Carbon.HIToolbox
import Foundation
import Observation

/// A key plus modifiers, stored with Carbon codes so it can be registered as a hot key.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key's printed name ("Space", "O", "F5"), captured when it was recorded.
    var keyName: String

    static let defaultCombo = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey),
                                       keyName: "Space")

    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + " " + keyName
    }

    /// Why this combo can't be used, or nil if it's fine.
    /// Since macOS 15, shortcuts whose only modifiers are ⌥ or ⇧⌥ register without an
    /// error but never fire, so every shortcut must include ⌘ or ⌃.
    var problem: String? {
        guard modifiers & UInt32(cmdKey | controlKey) != 0 else {
            return "Include ⌘ or ⌃. macOS doesn't allow shortcuts that use only ⌥ or ⇧."
        }
        return nil
    }

    /// Builds a combo from a key press in the recorder; nil for keys that can't be named.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        let code = Int(event.keyCode)
        let name = Self.specialKeyNames[code]
            ?? event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let name, !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(code), modifiers: UInt32(modifiers), keyName: name)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// A system-wide hold-to-talk shortcut. It uses Carbon hot keys, which report both
/// key-down and key-up and need no extra macOS permission.
@Observable @MainActor
final class VoiceShortcut {
    enum Status: Equatable {
        case active
        case unavailable(String)
    }

    private static let defaultsKey = "voiceShortcutCombo"

    var combo: KeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
            if isEnabled { register() }
        }
    }
    private(set) var status: Status = .unavailable("Not registered yet.")
    var isActive: Bool { status == .active }

    @ObservationIgnored var onPress: () -> Void = {}
    @ObservationIgnored var onRelease: () -> Void = {}
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var isDown = false
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
        combo = saved.flatMap { $0.problem == nil ? $0 : nil } ?? .defaultCombo
    }

    func register() {
        isEnabled = true
        unregisterHotKey()
        if let problem = combo.problem {
            status = .unavailable(problem)
            return
        }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4F52_4254), id: 1)  // 'ORBT'
        let result = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
        if result == noErr && ref != nil {
            status = .active
        } else {
            status = .unavailable("Another app is using \(combo.label). Pick a different shortcut.")
            Log.app.notice("Voice shortcut \(self.combo.label, privacy: .public) unavailable (status \(result))")
        }
    }

    /// Releases the hot key while the Settings recorder listens, so pressing the
    /// current shortcut there is recorded rather than starting a recording.
    func suspend() {
        unregisterHotKey()
    }

    func resume() {
        if isEnabled { register() }
    }

    private func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if isDown { onRelease() }
        isDown = false
    }

    fileprivate func handle(pressed: Bool) {
        // Ignore key-repeat presses while the shortcut is held.
        if pressed {
            guard !isDown else { return }
            isDown = true
            onPress()
        } else {
            guard isDown else { return }
            isDown = false
            onRelease()
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let shortcut = Unmanaged<VoiceShortcut>.fromOpaque(context).takeUnretainedValue()
            // Application-target Carbon events are delivered on the main thread.
            MainActor.assumeIsolated { shortcut.handle(pressed: pressed) }
            return noErr
        }, specs.count, &specs, context, &handlerRef)
    }
}
