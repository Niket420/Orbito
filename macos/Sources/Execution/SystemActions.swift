import AppKit
import CoreWLAN
import IOKit.ps

/// Runs a fixed program with arguments (never through a shell), off the main thread.
enum ProcessRunner {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stop.cancel()
                continuation.resume(returning: Output(status: process.terminationStatus,
                                                      stdout: String(decoding: stdout, as: UTF8.self),
                                                      stderr: String(decoding: stderr, as: UTF8.self)))
            }
        }
    }
}

/// Runs AppleScript through osascript. User text is only ever passed as arguments
/// (`argv`), never pasted into the script, so it can't change what the script does.
enum AppleScript {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    @discardableResult
    static func run(_ source: String, _ arguments: [String] = [], app: String, timeout: TimeInterval = 30) async throws -> String {
        let output = try await ProcessRunner.run("/usr/bin/osascript", ["-e", source] + arguments, timeout: timeout)
        guard output.status == 0 else {
            if output.stderr.contains("-1743") || output.stderr.contains("Not authorized") {
                throw Failure(errorDescription: "Orbito isn't allowed to control \(app). Turn it on in System Settings → "
                              + "Privacy & Security → Automation, then try again.")
            }
            Log.execution.error("AppleScript for \(app, privacy: .public) failed (\(output.status))")
            throw Failure(errorDescription: "\(app) didn't do it. Is \(app) set up on this Mac?")
        }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Facts about the Mac, phrased for the notch.
enum SystemInfo {
    static func battery() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return "I couldn't read the battery."
        }
        for source in sources {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let level = details[kIOPSCurrentCapacityKey] as? Int else { continue }
            let charging = details[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = details[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return "Battery is at \(level)%" + (charging ? " and charging." : plugged ? ", plugged in." : ".")
        }
        return "This Mac has no battery."
    }

    static func storage() -> String {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity else {
            return "I couldn't read the disk space."
        }
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "\(format(free)) free of \(format(Int64(total)))."
    }

    static func wifi() -> String {
        guard let interface = CWWiFiClient.shared().interface() else { return "This Mac has no Wi-Fi." }
        guard interface.powerOn() else { return "Wi-Fi is off." }
        // The network name needs Location access; without it, macOS hides it.
        if let name = interface.ssid() { return "Connected to \(name)." }
        return interface.rssiValue() != 0 ? "Wi-Fi is on and connected." : "Wi-Fi is on but not connected."
    }

    static func runningApps() -> String {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != .current }
            .compactMap(\.localizedName)
        return names.isEmpty ? "No other apps are open." : "Open apps: \(names.joined(separator: ", "))."
    }

    static func clipboard() -> String {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return "The clipboard has no text."
        }
        return "Clipboard: “\(text.prefix(300))\(text.count > 300 ? "…" : "")”"
    }

    static func time() -> String {
        "It's \(Date().formatted(date: .omitted, time: .shortened))."
    }

    static func date() -> String {
        "Today is \(Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year()))."
    }
}

/// Standard folders and System Settings panes.
enum Places {
    static func folder(_ location: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory: FileManager.SearchPathDirectory? = switch location {
        case "desktop": .desktopDirectory
        case "documents": .documentDirectory
        case "downloads": .downloadsDirectory
        case "applications": .applicationDirectory
        case "pictures": .picturesDirectory
        case "music": .musicDirectory
        case "movies": .moviesDirectory
        default: nil
        }
        if let directory, let url = FileManager.default.urls(for: directory, in: directory == .applicationDirectory
                                                             ? .localDomainMask : .userDomainMask).first {
            return url
        }
        switch location {
        case "trash": return home.appendingPathComponent(".Trash")
        case "icloud_drive": return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        default: return home
        }
    }

    /// `folder/name`, provided it stays inside `folder` and exists.
    static func subfolder(_ name: String, in folder: URL) -> URL? {
        let url = folder.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    static let settingsPanes: [String: String] = [
        "general": "com.apple.systempreferences.GeneralSettings",
        "wifi": "com.apple.wifi-settings-extension",
        "bluetooth": "com.apple.BluetoothSettings",
        "network": "com.apple.Network-Settings.extension",
        "sound": "com.apple.Sound-Settings.extension",
        "displays": "com.apple.Displays-Settings.extension",
        "battery": "com.apple.Battery-Settings.extension",
        "notifications": "com.apple.Notifications-Settings.extension",
        "focus": "com.apple.Focus-Settings.extension",
        "appearance": "com.apple.Appearance-Settings.extension",
        "wallpaper": "com.apple.Wallpaper-Settings.extension",
        "desktop_dock": "com.apple.Desktop-Settings.extension",
        "keyboard": "com.apple.Keyboard-Settings.extension",
        "trackpad": "com.apple.Trackpad-Settings.extension",
        "privacy": "com.apple.settings.PrivacySecurity.extension",
        "accessibility": "com.apple.Accessibility-Settings.extension",
        "users": "com.apple.Users-Groups-Settings.extension",
        "storage": "com.apple.settings.Storage",
        "software_update": "com.apple.Software-Update-Settings.extension",
    ]

    static func settingsURL(_ pane: String) -> URL? {
        settingsPanes[pane].flatMap { URL(string: "x-apple.systempreferences:\($0)") }
    }

    static func mediaSearchURL(_ query: String, app: String) -> URL {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "+", "="])) ?? ""
        switch app {
        case "spotify":
            let native = URL(string: "spotify:search:\(encoded)")!
            return NSWorkspace.shared.urlForApplication(toOpen: native) != nil
                ? native : URL(string: "https://open.spotify.com/search/\(encoded)")!
        case "apple_music":
            return URL(string: "music://music.apple.com/search?term=\(encoded)")!
        default:
            return URL(string: "https://www.youtube.com/results?search_query=\(encoded)")!
        }
    }

    static func mailtoURL(to: [String], subject: String?, body: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to.joined(separator: ",")
        let items = [subject.map { URLQueryItem(name: "subject", value: $0) },
                     body.map { URLQueryItem(name: "body", value: $0) }].compactMap { $0 }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}

/// Parses "YYYY-MM-DDTHH:MM" as local time.
enum LocalTime {
    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: text)
    }
}

/// Locks the screen right away (the same call as the menu bar's Lock Screen).
enum ScreenLock {
    static func lockNow() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFunction = @convention(c) () -> Int32
        _ = unsafeBitCast(symbol, to: LockFunction.self)()
        return true
    }
}
