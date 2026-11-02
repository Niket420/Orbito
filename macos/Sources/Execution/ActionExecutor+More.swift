import AppKit

/// Apps, windows, screen, files, system, media and productivity actions.
extension ActionExecutor {
    func executeMore(_ action: MacAction) async -> ExecutionOutcome {
        do {
            switch action {
            case .switchApplication(let name): return await switchApplication(name)
            case .hideApplication(let name, let others): return hideApplication(name, others: others)
            case .forceQuitApplication(let name): return await forceQuit(name)
            case .windowControl(let operation): return await windowControl(operation)
            case .appCommand(let command): return await appCommand(command)
            case .clickElement(let target): return await click(target)
            case .ask(_, let source): return await read(source)
            case .takeScreenshot(let area, let destination): return try await screenshot(area, to: destination)
            case .openLocation(let location, let subfolder): return openLocation(location, subfolder: subfolder)
            case .findFile(let query, let open): return try await findFile(query, open: open)
            case .createFolder(let name, let location): return try createFolder(name, in: location)
            case .trashSelectedFiles: return try await trashSelectedFiles()
            case .systemControl(let control, let value): return try await systemControl(control, value: value)
            case .openSettings(let pane): return openURL(Places.settingsURL(pane), done: "Opened System Settings.")
            case .getInfo(let item): return .ok(info(item))
            case .mediaControl(let command): return mediaControl(command)
            case .playMedia(let query, let app):
                return openURL(Places.mediaSearchURL(query, app: app), done: "Searched for “\(query)”.")
            case .createNote(let text): return try await createNote(text)
            case .createReminder(let title, let minutes, let due): return try await createReminder(title, in: minutes, due: due)
            case .listEvents(let day): return try await listEvents(day)
            case .createEvent(let title, let start, let minutes): return try await createEvent(title, start: start, minutes: minutes)
            case .composeEmail(let to, let subject, let body):
                return openURL(Places.mailtoURL(to: to, subject: subject, body: body), done: "Opened a new email draft.")
            case .setClipboard(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return .ok("Copied \(text.count) characters to the clipboard.")
            case .openApplication, .openURL, .searchWeb, .typeText, .pressKey, .closeApplication, .scroll:
                return .failure("Unexpected action.", retryable: false)
            }
        } catch {
            return .failure(error.localizedDescription, retryable: false)
        }
    }

    // MARK: - Apps and windows

    private func switchApplication(_ name: String?) async -> ExecutionOutcome {
        let target: NSRunningApplication?
        if let name {
            target = observer.runningApp(named: name)
            if target == nil { return await execute(.openApplication(name: name)) }  // not open yet
        } else {
            let front = observer.frontmostApp
            target = observer.lastExternalApp != front ? observer.lastExternalApp : observer.previousExternalApp
        }
        guard let target, !target.isTerminated else {
            return .failure("There's no previous app to switch to.", retryable: false)
        }
        target.unhide()
        target.activate()
        _ = await observer.waitUntil(timeout: .seconds(2)) { target.isActive }
        return .ok(observer.describeFront())
    }

    private func hideApplication(_ name: String, others: Bool) -> ExecutionOutcome {
        guard let app = observer.runningApp(named: name) else { return .ok("\(name) isn't open.") }
        if others {
            for other in NSWorkspace.shared.runningApplications
            where other.activationPolicy == .regular && other != app && other != .current {
                other.hide()
            }
            app.activate()
            return .ok("Hid every app except \(name).")
        }
        app.hide()
        return .ok("Hid \(name).")
    }

    private func forceQuit(_ name: String) async -> ExecutionOutcome {
        guard let app = observer.runningApp(named: name) else { return .ok("\(name) wasn't open.") }
        guard app != .current else { return .failure("I can't force quit myself.", retryable: false) }
        app.forceTerminate()
        let gone = await observer.waitUntil(timeout: .seconds(3)) { app.isTerminated }
        return gone ? .ok("Force quit \(name).") : .failure("\(name) didn't quit.", retryable: true)
    }

    private func windowControl(_ operation: String) async -> ExecutionOutcome {
        if let problem = await prepareForInput() { return problem }
        do {
            try AccessibilityController.controlFrontWindow(operation)
        } catch {
            return .failure(error.localizedDescription, retryable: false)
        }
        try? await Task.sleep(for: .milliseconds(300))
        return .ok("Window: \(operation.replacingOccurrences(of: "_", with: " ")). \(observer.describeFront())")
    }

    private func appCommand(_ command: String) async -> ExecutionOutcome {
        guard let shortcut = MacAction.appCommands[command] else {
            return .failure("Unknown command.", retryable: false)
        }
        if let problem = await prepareForInput() { return problem }
        _ = InputController.press(key: shortcut.key, modifiers: shortcut.modifiers)
        try? await Task.sleep(for: .milliseconds(300))
        return .ok("\(command.replacingOccurrences(of: "_", with: " ").capitalized). \(observer.describeFront())")
    }

    private func click(_ target: String) async -> ExecutionOutcome {
        if let problem = await prepareForInput() { return problem }
        let app = observer.frontmostApp?.localizedName ?? "the app in front"
        guard let clicked = AccessibilityController.click(target) else {
            return .failure("I couldn't find “\(target)” in \(app).", retryable: true)
        }
        try? await Task.sleep(for: .milliseconds(400))
        return .ok("Clicked “\(clicked.prefix(60))”. \(observer.describeFront())")
    }

    // MARK: - Reading the screen

    /// Text for the backend to answer a question from. The observation carries the text itself.
    private func read(_ source: String) async -> ExecutionOutcome {
        switch source {
        case "none":
            return .ok("")
        case "clipboard":
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                return .failure("The clipboard has no text.", retryable: false)
            }
            return .ok(text)
        default:
            if let problem = await prepareForInput() { return problem }
            let app = observer.frontmostApp?.localizedName ?? "this app"
            if source == "selection" {
                guard let text = await selectedText() else {
                    return .failure("Select some text in \(app) first.", retryable: false)
                }
                return .ok(text)
            }
            let text = AccessibilityController.visibleText()
            guard text.count > 20 else {
                return .failure("I couldn't read the text in \(app); it doesn't share it with macOS.", retryable: false)
            }
            return .ok(text)
        }
    }

    /// The selected text, read directly or, for apps that don't expose it, by copying it
    /// and putting the clipboard back afterwards.
    private func selectedText() async -> String? {
        if let text = AccessibilityController.selectedText() { return text }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let before = pasteboard.changeCount
        _ = InputController.press(key: "c", modifiers: ["command"])
        _ = await observer.waitUntil(timeout: .milliseconds(600)) { pasteboard.changeCount != before }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
        return text?.isEmpty == false ? text : nil
    }

    // MARK: - Screenshots and files

    private func screenshot(_ area: String, to destination: String) async throws -> ExecutionOutcome {
        var arguments: [String] = []
        switch area {
        case "window":
            let app = observer.isSelfFrontmost ? observer.lastExternalApp : observer.frontmostApp
            guard let pid = app?.processIdentifier, let id = Self.frontWindowID(of: pid) else {
                return .failure("There's no window to capture.", retryable: false)
            }
            arguments.append("-l\(id)")
        case "selection": arguments.append("-i")
        default: break
        }
        if destination == "clipboard" {
            arguments.append("-c")
            _ = try await ProcessRunner.run("/usr/sbin/screencapture", arguments, timeout: 60)
            return .ok("Copied the screenshot to the clipboard.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = Places.folder("desktop").appendingPathComponent("Screenshot \(formatter.string(from: Date())).png")
        _ = try await ProcessRunner.run("/usr/sbin/screencapture", arguments + [file.path], timeout: 60)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return area == "selection"
                ? .ok("Screenshot cancelled.")
                : .failure("The screenshot wasn't saved. Orbito may need Screen Recording permission "
                           + "(System Settings → Privacy & Security).", retryable: false)
        }
        return .ok("Saved “\(file.lastPathComponent)” to the Desktop.")
    }

    private static func frontWindowID(of pid: pid_t) -> CGWindowID? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let window = windows.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        return window?[kCGWindowNumber as String] as? CGWindowID
    }

    private func openLocation(_ location: String, subfolder: String?) -> ExecutionOutcome {
        var url = Places.folder(location)
        if let subfolder {
            guard let inside = Places.subfolder(subfolder, in: url) else {
                return .failure("There's no folder “\(subfolder)” in \(location).", retryable: false)
            }
            url = inside
        }
        return NSWorkspace.shared.open(url)
            ? .ok("Opened \(url.lastPathComponent) in Finder.")
            : .failure("Couldn't open \(url.lastPathComponent).", retryable: false)
    }

    private func findFile(_ query: String, open: Bool) async throws -> ExecutionOutcome {
        let home = NSHomeDirectory()
        let output = try await ProcessRunner.run("/usr/bin/mdfind", ["-onlyin", home, "-name", query], timeout: 15)
        let matches = output.stdout.split(separator: "\n").map(String.init)
            .filter { !$0.contains("/Library/") && !$0.contains("/.") }
            .sorted { $0.count < $1.count }
        guard let best = matches.first else {
            return .failure("I couldn't find a file called “\(query)”.", retryable: false)
        }
        if open {
            NSWorkspace.shared.open(URL(fileURLWithPath: best))
            return .ok("Opened \((best as NSString).lastPathComponent).")
        }
        let shown = matches.prefix(5).map { path -> String in
            let url = URL(fileURLWithPath: path)
            let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            return "\(url.lastPathComponent) (in \(folder))"
        }
        return .ok("Found \(matches.count == 1 ? "1 file" : "\(matches.count) files"): \(shown.joined(separator: "; ")).")
    }

    private func createFolder(_ name: String, in location: String) throws -> ExecutionOutcome {
        let url = Places.folder(location).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return .ok("“\(name)” already exists.") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return .ok("Created the folder “\(name)” in \(url.deletingLastPathComponent().lastPathComponent).")
    }

    private func trashSelectedFiles() async throws -> ExecutionOutcome {
        let count = try await AppleScript.run("""
            tell application "Finder"
                set picked to selection
                set n to count of picked
                if n > 0 then delete picked
                return n
            end tell
            """, app: "Finder")
        guard let n = Int(count), n > 0 else {
            return .failure("Nothing is selected in Finder.", retryable: false)
        }
        return .ok("Moved \(n == 1 ? "1 item" : "\(n) items") to the Trash.")
    }

    // MARK: - System

    private func systemControl(_ control: String, value: Int?) async throws -> ExecutionOutcome {
        switch control {
        case "volume_up", "volume_down", "set_volume":
            let current = Int(try await AppleScript.run("output volume of (get volume settings)", app: "Sound")) ?? 50
            let step = value ?? 10
            let level = control == "set_volume" ? (value ?? current)
                : max(0, min(100, current + (control == "volume_up" ? step : -step)))
            try await AppleScript.run("on run argv\nset volume output volume (item 1 of argv as integer)\nend run",
                                      [String(level)], app: "Sound")
            return .ok("Volume is now \(level)%.")
        case "mute", "unmute":
            try await AppleScript.run("set volume output muted \(control == "mute")", app: "Sound")
            return .ok(control == "mute" ? "Muted." : "Unmuted.")
        case "brightness_up", "brightness_down":
            // Each key press is one of 16 steps.
            let presses = max(1, Int((Double(value ?? 25) / 6.25).rounded()))
            for _ in 0..<presses {
                InputController.press(control == "brightness_up" ? .brightnessUp : .brightnessDown)
                try? await Task.sleep(for: .milliseconds(40))
            }
            return .ok(control == "brightness_up" ? "Turned the brightness up." : "Turned the brightness down.")
        case "dark_mode_on", "dark_mode_off":
            let on = control == "dark_mode_on"
            try await AppleScript.run(
                "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)",
                app: "System Events")
            return .ok(on ? "Dark mode is on." : "Light mode is on.")
        case "wifi_on", "wifi_off":
            let ports = try await ProcessRunner.run("/usr/sbin/networksetup", ["-listallhardwareports"])
            let lines = ports.stdout.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("Wi-Fi") || $0.contains("AirPort") }),
                  index + 1 < lines.count, lines[index + 1].hasPrefix("Device: ") else {
                return .failure("This Mac has no Wi-Fi.", retryable: false)
            }
            let device = String(lines[index + 1].dropFirst("Device: ".count))
            let on = control == "wifi_on"
            let result = try await ProcessRunner.run("/usr/sbin/networksetup", ["-setairportpower", device, on ? "on" : "off"])
            guard result.status == 0 else { return .failure("macOS didn't change Wi-Fi.", retryable: false) }
            return .ok(on ? "Wi-Fi is on." : "Wi-Fi is off.")
        case "lock_screen":
            if ScreenLock.lockNow() { return .ok("Locked the screen.") }
            _ = try await ProcessRunner.run("/usr/bin/pmset", ["displaysleepnow"])
            return .ok("Turned the display off.")
        case "sleep":
            _ = try await ProcessRunner.run("/usr/bin/pmset", ["sleepnow"])
            return .ok("Going to sleep.")
        default:
            return .failure("Unknown setting.", retryable: false)
        }
    }

    private func info(_ item: String) -> String {
        switch item {
        case "battery": SystemInfo.battery()
        case "storage": SystemInfo.storage()
        case "wifi": SystemInfo.wifi()
        case "time": SystemInfo.time()
        case "date": SystemInfo.date()
        case "running_apps": SystemInfo.runningApps()
        case "clipboard": SystemInfo.clipboard()
        default: observer.describeFront() + "."
        }
    }

    private func mediaControl(_ command: String) -> ExecutionOutcome {
        let key: InputController.SpecialKey = command == "next" ? .next : command == "previous" ? .previous : .playPause
        InputController.press(key)
        return .ok(command == "next" ? "Next track." : command == "previous" ? "Previous track." : "Play/pause.")
    }

    private func openURL(_ url: URL?, done: String) -> ExecutionOutcome {
        guard let url, NSWorkspace.shared.open(url) else {
            return .failure("macOS couldn't open that.", retryable: false)
        }
        return .ok(done)
    }

    // MARK: - Notes, Reminders, Calendar

    private func createNote(_ text: String) async throws -> ExecutionOutcome {
        // Notes takes HTML; escape it so the text appears exactly as said.
        let html = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        try await AppleScript.run("""
            on run argv
                tell application "Notes" to make new note with properties {body:item 1 of argv}
            end run
            """, [html], app: "Notes")
        return .ok("Added a note in Notes.")
    }

    private func createReminder(_ title: String, in minutes: Int?, due: String?) async throws -> ExecutionOutcome {
        var seconds = 0
        if let minutes { seconds = minutes * 60 }
        if let due {
            guard let date = LocalTime.date(due), date > Date() else {
                return .failure("That reminder time has already passed.", retryable: false)
            }
            seconds = Int(date.timeIntervalSinceNow.rounded())
        }
        try await AppleScript.run("""
            on run argv
                set t to item 1 of argv
                set s to item 2 of argv as integer
                set d to (current date) + s
                tell application "Reminders"
                    if s > 0 then
                        make new reminder with properties {name:t, remind me date:d}
                    else
                        make new reminder with properties {name:t}
                    end if
                end tell
            end run
            """, [title, String(seconds)], app: "Reminders")
        guard seconds > 0 else { return .ok("Added “\(title)” to Reminders.") }
        let when = Date().addingTimeInterval(TimeInterval(seconds)).formatted(date: .omitted, time: .shortened)
        return .ok("I'll remind you at \(when): “\(title)”.")
    }

    private func listEvents(_ day: String) async throws -> ExecutionOutcome {
        let output = try await AppleScript.run("""
            on run argv
                set startDate to current date
                set time of startDate to 0
                set startDate to startDate + (item 1 of argv as integer) * days
                set endDate to startDate + 1 * days
                set found to {}
                tell application "Calendar"
                    repeat with c in calendars
                        repeat with e in (every event of c whose start date ≥ startDate and start date < endDate)
                            set sd to start date of e
                            set end of found to ((hours of sd) * 60 + (minutes of sd) as text) & tab & (summary of e)
                        end repeat
                    end repeat
                end tell
                set AppleScript's text item delimiters to linefeed
                return found as text
            end run
            """, [day == "tomorrow" ? "1" : "0"], app: "Calendar", timeout: 45)
        let events = output.split(separator: "\n").compactMap { line -> (Int, String)? in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let minute = Int(parts[0]) else { return nil }
            return (minute, String(parts[1]))
        }.sorted { $0.0 < $1.0 }
        guard !events.isEmpty else { return .ok("Nothing on your calendar \(day).") }
        let start = Calendar.current.startOfDay(for: Date())
        let list = events.map { minute, title in
            "\(start.addingTimeInterval(TimeInterval(minute * 60)).formatted(date: .omitted, time: .shortened)) \(title)"
        }
        return .ok("\(day.capitalized): \(list.joined(separator: "; ")).")
    }

    private func createEvent(_ title: String, start: String, minutes: Int) async throws -> ExecutionOutcome {
        guard let date = LocalTime.date(start) else { return .failure("That time isn't valid.", retryable: false) }
        let offset = Int(date.timeIntervalSinceNow.rounded())
        try await AppleScript.run("""
            on run argv
                set t to item 1 of argv
                set s to (current date) + (item 2 of argv as integer) + 30
                set s to s - (seconds of s)
                set e to s + (item 3 of argv as integer) * minutes
                tell application "Calendar"
                    tell (first calendar whose writable is true)
                        make new event with properties {summary:t, start date:s, end date:e}
                    end tell
                end tell
            end run
            """, [title, String(offset), String(minutes)], app: "Calendar")
        return .ok("Added “\(title)” on \(date.formatted(date: .abbreviated, time: .shortened)).")
    }
}
