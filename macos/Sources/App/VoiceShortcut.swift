import CoreGraphics
import Foundation
import Observation

/// Two modifier keys start Orbito: tap them, or hold them while speaking.
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

/// Recognizes exactly the preset's two modifiers, used alone (so shortcuts like ⌃⌥⌘T,
/// ⌃⌥Space or ⌃→ never trigger it):
/// - a quick tap (released within `holdDelay`) → `.tap`
/// - holding them → `.holdStarted`, then `.holdEnded` on release (hold-to-talk), or
///   `.holdCancelled` if another key or modifier joins in.
struct ModifierTapDetector {
    enum Event: Equatable {
        case tap, holdStarted, holdEnded, holdCancelled
    }

    static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]
    static let holdDelay: TimeInterval = 0.35

    var target: CGEventFlags
    private var pressedAt: TimeInterval?
    private var spoiled = false
    private var holding = false

    init(target: CGEventFlags) {
        self.target = target
    }

    /// Feed the current modifier state; returns what happened, if anything.
    mutating func update(flags rawFlags: CGEventFlags, now: TimeInterval, secondsSinceKeyDown: TimeInterval) -> Event? {
        let flags = rawFlags.intersection(Self.relevant)
        if let pressedAt, !spoiled, secondsSinceKeyDown < now - pressedAt {
            spoiled = true  // another key was pressed while the modifiers were down
            if holding { holding = false; return .holdCancelled }
        }
        if flags.isEmpty {
            defer { pressedAt = nil; spoiled = false; holding = false }
            guard let pressedAt, !spoiled else { return nil }
            if holding { return .holdEnded }
            return now - pressedAt < Self.holdDelay ? .tap : nil
        }
        if flags == target {
            if pressedAt == nil { pressedAt = now }
            if let pressedAt, !spoiled, !holding, now - pressedAt >= Self.holdDelay {
                holding = true
                return .holdStarted
            }
        } else if !target.isSuperset(of: flags), !spoiled {
            spoiled = true  // another modifier joined in
            if holding { holding = false; return .holdCancelled }
        }
        return nil
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

    @ObservationIgnored var onEvent: (ModifierTapDetector.Event) -> Void = { _ in }
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
        if let event = detector.update(flags: flags, now: ProcessInfo.processInfo.systemUptime,
                                       secondsSinceKeyDown: sinceKey) {
            onEvent(event)
        }
    }
}
