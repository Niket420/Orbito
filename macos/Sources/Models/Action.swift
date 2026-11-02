import Foundation

enum ActionStatus: String, Codable, Equatable {
    case queued
    case awaitingApproval = "awaiting_approval"
    case ready
    case succeeded
    case failed
    case skipped
}

/// An action exactly as the backend sent it. Never executed directly:
/// it must first be converted into a `MacAction`, which re-validates it.
struct ActionDTO: Codable, Equatable, Identifiable {
    let actionId: String
    let type: String
    let parameters: [String: JSONValue]
    let description: String
    let requiresApproval: Bool
    let status: ActionStatus
    let attempt: Int
    let observation: String?
    let error: String?

    var id: String { actionId }

    enum CodingKeys: String, CodingKey {
        case actionId = "action_id", type, parameters, description
        case requiresApproval = "requires_approval"
        case status, attempt, observation, error
    }
}

enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct ActionValidationError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// The macOS app's own allowlist. It mirrors backend/app/policy/permissions.py and
/// is enforced independently, so a compromised or buggy backend still cannot make
/// the app do anything outside this list.
enum MacAction: Equatable {
    case openApplication(name: String)
    case openURL(URL, app: String?)
    case searchWeb(query: String, app: String?)
    case typeText(String)
    case pressKey(key: String, modifiers: [String])
    case closeApplication(name: String)
    case scroll(direction: String, lines: Int)
    case switchApplication(name: String?)
    case hideApplication(name: String, others: Bool)
    case forceQuitApplication(name: String)
    case windowControl(String)
    case appCommand(String)
    case clickElement(String)
    case ask(question: String, source: String)
    case takeScreenshot(area: String, destination: String)
    case openLocation(String, subfolder: String?)
    case findFile(query: String, open: Bool)
    case createFolder(name: String, location: String)
    case trashSelectedFiles
    case systemControl(String, value: Int?)
    case openSettings(String)
    case getInfo(String)
    case mediaControl(String)
    case playMedia(query: String, app: String)
    case createNote(String)
    case createReminder(title: String, inMinutes: Int?, due: String?)
    case listEvents(day: String)
    case createEvent(title: String, start: String, minutes: Int)
    case composeEmail(to: [String], subject: String?, body: String?)
    case setClipboard(String)

    static let windowOperations = ["minimize", "maximize", "fullscreen", "left_half", "right_half", "top_half",
                                   "bottom_half", "center", "close", "next_display"]
    /// Named commands and the shortcut each one sends.
    static let appCommands: [String: (key: String, modifiers: [String])] = [
        "copy": ("c", ["command"]), "cut": ("x", ["command"]), "paste": ("v", ["command"]),
        "select_all": ("a", ["command"]), "undo": ("z", ["command"]), "redo": ("z", ["command", "shift"]),
        "save": ("s", ["command"]), "find": ("f", ["command"]), "new_tab": ("t", ["command"]),
        "close_tab": ("w", ["command"]), "reopen_tab": ("t", ["command", "shift"]),
        "next_tab": ("tab", ["control"]), "previous_tab": ("tab", ["control", "shift"]),
        "back": ("[", ["command"]), "forward": ("]", ["command"]), "reload": ("r", ["command"]),
        "new_window": ("n", ["command"]), "address_bar": ("l", ["command"]),
        "zoom_in": ("=", ["command"]), "zoom_out": ("-", ["command"]), "actual_size": ("0", ["command"]),
    ]
    static let riskyClickWords = ["delete", "remove", "erase", "trash", "buy", "pay", "purchase", "order",
                                  "checkout", "send", "submit", "post", "publish", "confirm", "transfer",
                                  "sign out", "log out", "uninstall", "unsubscribe", "discard", "reset", "format"]
    static let locations = ["home", "desktop", "documents", "downloads", "applications", "pictures", "music",
                            "movies", "trash", "icloud_drive"]
    static let systemControls = ["volume_up", "volume_down", "set_volume", "mute", "unmute", "brightness_up",
                                 "brightness_down", "dark_mode_on", "dark_mode_off", "wifi_on", "wifi_off",
                                 "lock_screen", "sleep"]
    static let riskySystemControls: Set<String> = ["wifi_off", "lock_screen", "sleep"]
    static let settingsPanes = ["general", "wifi", "bluetooth", "network", "sound", "displays", "battery",
                                "notifications", "focus", "appearance", "wallpaper", "desktop_dock", "keyboard",
                                "trackpad", "privacy", "accessibility", "users", "storage", "software_update"]
    static let infoItems = ["battery", "storage", "wifi", "time", "date", "running_apps", "clipboard", "front_app"]

    static let allowedKeys: Set<String> = Set(
        ["return", "tab", "escape", "space", "delete", "up", "down", "left", "right"]
        + "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
    static let allowedModifiers: Set<String> = ["command", "shift", "option", "control"]
    static let blockedShortcuts: Set<Set<String>> = [
        ["command", "q"], ["command", "option", "escape"], ["control", "command", "q"],
        ["command", "shift", "q"], ["command", "option", "shift", "q"],
        ["command", "delete"], ["command", "shift", "delete"], ["command", "option", "shift", "delete"],
    ]

    init(_ dto: ActionDTO) throws {
        let p = Params(dto.parameters)
        switch dto.type {
        case "open_application":
            try p.only(["application_name"])
            self = .openApplication(name: try p.appName("application_name")!)
        case "open_url":
            try p.only(["url", "application_name"])
            let raw = try p.string("url", maxLength: 2048)!
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
                throw ActionValidationError(message: "Only http(s) links can be opened.")
            }
            self = .openURL(url, app: try p.appName("application_name", required: false))
        case "search_web":
            try p.only(["query", "application_name"])
            self = .searchWeb(query: try p.string("query", maxLength: 300)!,
                              app: try p.appName("application_name", required: false))
        case "type_text":
            try p.only(["text"])
            self = .typeText(try p.string("text", maxLength: 500, trim: false)!)
        case "press_key":
            try p.only(["key", "modifiers"])
            let key = try p.string("key", maxLength: 10)!.lowercased()
            let modifiers = try p.stringArray("modifiers").map { $0.lowercased() }
            guard Self.allowedKeys.contains(key) else { throw ActionValidationError(message: "Key “\(key)” isn't allowed.") }
            guard Set(modifiers).isSubset(of: Self.allowedModifiers), modifiers.count <= 3 else {
                throw ActionValidationError(message: "Unsupported keyboard modifiers.")
            }
            guard !Self.blockedShortcuts.contains(Set(modifiers + [key])) else {
                throw ActionValidationError(message: "That keyboard shortcut is blocked for safety.")
            }
            self = .pressKey(key: key, modifiers: modifiers)
        case "close_application":
            try p.only(["application_name"])
            self = .closeApplication(name: try p.appName("application_name")!)
        case "scroll":
            try p.only(["direction", "amount"])
            let direction = try p.string("direction", maxLength: 5)!
            guard ["up", "down", "left", "right"].contains(direction) else {
                throw ActionValidationError(message: "Scroll direction “\(direction)” isn't allowed.")
            }
            let lines = try p.int("amount", in: 1...30) ?? 5
            self = .scroll(direction: direction, lines: lines)
        case "switch_application":
            try p.only(["application_name"])
            self = .switchApplication(name: try p.appName("application_name", required: false))
        case "hide_application":
            try p.only(["application_name", "others"])
            self = .hideApplication(name: try p.appName("application_name")!, others: try p.bool("others"))
        case "force_quit_application":
            try p.only(["application_name"])
            self = .forceQuitApplication(name: try p.appName("application_name")!)
        case "window_control":
            try p.only(["operation"])
            self = .windowControl(try p.oneOf("operation", Self.windowOperations)!)
        case "app_command":
            try p.only(["command"])
            self = .appCommand(try p.oneOf("command", Array(Self.appCommands.keys))!)
        case "click_element":
            try p.only(["target"])
            self = .clickElement(try p.string("target", maxLength: 80)!)
        case "ask":
            try p.only(["question", "source"])
            self = .ask(question: try p.string("question", maxLength: 300)!,
                        source: try p.oneOf("source", ["screen", "selection", "clipboard", "none"], default: "none")!)
        case "take_screenshot":
            try p.only(["area", "destination"])
            self = .takeScreenshot(area: try p.oneOf("area", ["full", "window", "selection"], default: "full")!,
                                   destination: try p.oneOf("destination", ["file", "clipboard"], default: "file")!)
        case "open_location":
            try p.only(["location", "subfolder"])
            self = .openLocation(try p.oneOf("location", Self.locations)!,
                                 subfolder: try p.fileName("subfolder", required: false))
        case "find_file":
            try p.only(["query", "open"])
            self = .findFile(query: try p.string("query", maxLength: 120)!, open: try p.bool("open"))
        case "create_folder":
            try p.only(["name", "location"])
            self = .createFolder(name: try p.fileName("name")!,
                                 location: try p.oneOf("location", Self.locations, default: "desktop")!)
        case "trash_selected_files":
            try p.only([])
            self = .trashSelectedFiles
        case "system_control":
            try p.only(["control", "value"])
            self = .systemControl(try p.oneOf("control", Self.systemControls)!, value: try p.int("value", in: 0...100))
        case "open_settings":
            try p.only(["pane"])
            self = .openSettings(try p.oneOf("pane", Self.settingsPanes)!)
        case "get_info":
            try p.only(["item"])
            self = .getInfo(try p.oneOf("item", Self.infoItems)!)
        case "media_control":
            try p.only(["command"])
            self = .mediaControl(try p.oneOf("command", ["play_pause", "next", "previous"])!)
        case "play_media":
            try p.only(["query", "app"])
            self = .playMedia(query: try p.string("query", maxLength: 200)!,
                              app: try p.oneOf("app", ["spotify", "apple_music", "youtube"], default: "youtube")!)
        case "create_note":
            try p.only(["text"])
            self = .createNote(try p.string("text", maxLength: 2000, trim: false)!)
        case "create_reminder":
            try p.only(["title", "in_minutes", "due"])
            self = .createReminder(title: try p.string("title", maxLength: 200)!,
                                   inMinutes: try p.int("in_minutes", in: 1...10080),
                                   due: try p.localDateTime("due", required: false))
        case "list_events":
            try p.only(["day"])
            self = .listEvents(day: try p.oneOf("day", ["today", "tomorrow"], default: "today")!)
        case "create_event":
            try p.only(["title", "start", "duration_minutes"])
            self = .createEvent(title: try p.string("title", maxLength: 200)!,
                                start: try p.localDateTime("start")!,
                                minutes: try p.int("duration_minutes", in: 5...1440) ?? 60)
        case "compose_email":
            try p.only(["to", "subject", "body"])
            let to = try p.stringArray("to")
            guard to.count <= 5, to.allSatisfy(Self.isEmail) else {
                throw ActionValidationError(message: "Those aren't valid email addresses.")
            }
            self = .composeEmail(to: to, subject: try p.string("subject", maxLength: 200, required: false),
                                 body: try p.string("body", maxLength: 2000, required: false, trim: false))
        case "set_clipboard":
            try p.only(["text"])
            self = .setClipboard(try p.string("text", maxLength: 2000, trim: false)!)
        default:
            throw ActionValidationError(message: "Unsupported action “\(dto.type)”.")
        }
    }

    /// The app's own risk policy: free-form input and anything hard to undo needs approval.
    var requiresApproval: Bool {
        switch self {
        case .typeText, .pressKey, .forceQuitApplication, .trashSelectedFiles, .createEvent: true
        case .clickElement(let target):
            Self.riskyClickWords.contains { target.lowercased().contains($0) }
        case .systemControl(let control, _): Self.riskySystemControls.contains(control)
        default: false
        }
    }

    static func isEmail(_ value: String) -> Bool {
        value.range(of: #"^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$"#, options: .regularExpression) != nil
    }
}

/// Strict accessors over untyped action parameters.
private struct Params {
    let values: [String: JSONValue]
    init(_ values: [String: JSONValue]) { self.values = values }

    func only(_ allowed: Set<String>) throws {
        let extra = Set(values.keys).subtracting(allowed)
        if !extra.isEmpty { throw ActionValidationError(message: "Unexpected parameters: \(extra.sorted().joined(separator: ", "))") }
    }

    func string(_ key: String, maxLength: Int, required: Bool = true, trim: Bool = true) throws -> String? {
        switch values[key] {
        case .string(let raw)?:
            let value = trim ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
            guard !value.isEmpty, value.count <= maxLength else {
                throw ActionValidationError(message: "Parameter “\(key)” is empty or too long.")
            }
            return value
        case nil, .null?:
            if required { throw ActionValidationError(message: "Missing parameter “\(key)”.") }
            return nil
        default:
            throw ActionValidationError(message: "Parameter “\(key)” must be text.")
        }
    }

    func appName(_ key: String, required: Bool = true) throws -> String? {
        guard let name = try string(key, maxLength: 80, required: required) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .&'+-_"))
        guard name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ActionValidationError(message: "That app name contains unsupported characters.")
        }
        return name
    }

    func int(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        switch values[key] {
        case nil, .null?: return nil
        case .number(let n)? where n == n.rounded() && range.contains(Int(n)): return Int(n)
        default: throw ActionValidationError(message: "“\(key)” must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
    }

    func bool(_ key: String) throws -> Bool {
        switch values[key] {
        case nil, .null?: return false
        case .bool(let b)?: return b
        default: throw ActionValidationError(message: "“\(key)” must be true or false.")
        }
    }

    /// One of a fixed set of values.
    func oneOf(_ key: String, _ options: [String], default fallback: String? = nil) throws -> String? {
        guard let value = try string(key, maxLength: 40, required: fallback == nil) else { return fallback }
        guard options.contains(value) else { throw ActionValidationError(message: "“\(value)” isn't allowed for \(key).") }
        return value
    }

    /// A plain file or folder name: no slashes, colons or leading dot.
    func fileName(_ key: String, required: Bool = true) throws -> String? {
        guard let name = try string(key, maxLength: 120, required: required) else { return nil }
        guard !name.hasPrefix("."), name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\\0")) == nil else {
            throw ActionValidationError(message: "“\(key)” must be a plain file or folder name.")
        }
        return name
    }

    /// Local time as YYYY-MM-DDTHH:MM.
    func localDateTime(_ key: String, required: Bool = true) throws -> String? {
        guard let value = try string(key, maxLength: 16, required: required) else { return nil }
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$"#, options: .regularExpression) != nil else {
            throw ActionValidationError(message: "“\(key)” must be a time like 2026-05-01T18:30.")
        }
        return value
    }

    func stringArray(_ key: String) throws -> [String] {
        switch values[key] {
        case nil, .null?: return []
        case .array(let items)?:
            return try items.map {
                guard case .string(let s) = $0 else { throw ActionValidationError(message: "“\(key)” must be a list of text.") }
                return s
            }
        default: throw ActionValidationError(message: "“\(key)” must be a list.")
        }
    }
}
