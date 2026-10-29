import CoreGraphics
import Foundation
import Observation

/// Two modifier keys pressed together and released (a "tap") start Orbito.
enum ShortcutPreset: String, CaseIterable, Identifiable {
    case controlOption
    case fnControl
    case optionCommand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .controlOption: "⌃ Control + ⌥ Option"
        case .fnControl: "fn + ⌃ Control"
        case .optionCommand: "⌥ Option + ⌘ Command"
        }
    }

    var shortLabel: String {
        switch self {
        case .controlOption: "⌃⌥"
        case .fnControl: "fn⌃"
        case .optionCommand: "⌥⌘"
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .controlOption: [.maskControl, .maskAlternate]
        case .fnControl: [.maskSecondaryFn, .maskControl]
        case .optionCommand: [.maskAlternate, .maskCommand]
        }
    }
}

/// Recognizes a tap of exactly the preset's modifiers: pressed together, then all
/// released within `maxHold`, with no other key or modifier used in between (so
/// shortcuts like ⌃⌥⌘T or ⌃→ never trigger it).
struct ModifierTapDetector {
    static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]
    static let maxHold: TimeInterval = 0.8

    var target: CGEventFlags
    private var pressedAt: TimeInterval?
    private var spoiled = false

    init(target: CGEventFlags) {
        self.target = target
    }

    /// Feed the current modifier state; returns true when a tap completes.
    mutating func update(flags rawFlags: CGEventFlags, now: TimeInterval, secondsSinceKeyDown: TimeInterval) -> Bool {
        let flags = rawFlags.intersection(Self.relevant)
        if flags.isEmpty {
            defer { pressedAt = nil; spoiled = false }
            guard let pressedAt, !spoiled else { return false }
            let held = now - pressedAt
            return held <= Self.maxHold && secondsSinceKeyDown > held
        }
        if flags == target {
            if pressedAt == nil { pressedAt = now }
        } else if !target.isSuperset(of: flags) {
            spoiled = true  // another modifier joined in
        }
        return false
    }
}

/// System-wide shortcut. Modifier keys can't be registered as hot keys, so the global
/// modifier state is sampled about 30 times a second, which needs no macOS permission.
@Observable @MainActor
final class VoiceShortcut {
    private static let defaultsKey = "voiceShortcutPreset"

    var preset: ShortcutPreset {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: Self.defaultsKey)
            detector = ModifierTapDetector(target: preset.flags)
        }
    }

    @ObservationIgnored var onTap: () -> Void = {}
    @ObservationIgnored private var detector: ModifierTapDetector
    @ObservationIgnored private var timer: Timer?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(ShortcutPreset.init(rawValue:))
        preset = saved ?? .controlOption
        detector = ModifierTapDetector(target: (saved ?? .controlOption).flags)
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if detector.update(flags: flags, now: ProcessInfo.processInfo.systemUptime, secondsSinceKeyDown: sinceKey) {
            onTap()
        }
    }
}
