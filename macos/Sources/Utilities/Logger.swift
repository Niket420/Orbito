import Foundation
import os

/// Unified-logging categories. View with:
/// `log stream --predicate 'subsystem == "dev.orbito.assistant"'`
/// Instructions, transcripts and typed text are never logged.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dev.orbito.assistant"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let backend = Logger(subsystem: subsystem, category: "backend")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let execution = Logger(subsystem: subsystem, category: "execution")
}

enum AppPaths {
    /// ~/Library/Application Support/Orbito (shared with the Python backend).
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Orbito", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var backendLog: URL { supportDirectory.appendingPathComponent("backend.log") }
    static var tokenFile: URL { supportDirectory.appendingPathComponent("api-token") }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
