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
        default:
            throw ActionValidationError(message: "Unsupported action “\(dto.type)”.")
        }
    }

    /// The app's own risk policy: input simulation always needs explicit approval.
    var requiresApproval: Bool {
        switch self {
        case .typeText, .pressKey: true
        case .openApplication, .openURL, .searchWeb, .closeApplication, .scroll: false
        }
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
