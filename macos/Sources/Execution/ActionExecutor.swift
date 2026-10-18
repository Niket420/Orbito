import AppKit

struct ExecutionOutcome: Equatable {
    let success: Bool
    let observation: String?
    let error: String?
    let retryable: Bool

    static func ok(_ observation: String) -> ExecutionOutcome {
        ExecutionOutcome(success: true, observation: observation, error: nil, retryable: false)
    }

    static func failure(_ error: String, retryable: Bool, observation: String? = nil) -> ExecutionOutcome {
        ExecutionOutcome(success: false, observation: observation, error: error, retryable: retryable)
    }
}

/// Executes validated `MacAction`s and verifies their effect where possible.
@MainActor
final class ActionExecutor {
    let observer = ScreenObserver()

    func execute(_ action: MacAction) async -> ExecutionOutcome {
        Log.execution.info("Executing \(String(describing: action.kind), privacy: .public)")
        let outcome: ExecutionOutcome
        switch action {
        case .openApplication(let name): outcome = await openApplication(name)
        case .openURL(let url, let app): outcome = await open(url, in: app)
        case .searchWeb(let query, let app): outcome = await open(Self.searchURL(for: query), in: app)
        case .typeText(let text): outcome = await typeText(text)
        case .pressKey(let key, let modifiers): outcome = await pressKey(key, modifiers: modifiers)
        }
        Log.execution.info("Result: success=\(outcome.success)")
        return outcome
    }

    nonisolated static func searchURL(for query: String) -> URL {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }

    // MARK: - Actions

    private func openApplication(_ name: String) async -> ExecutionOutcome {
        if let running = observer.runningApp(named: name) {
            running.unhide()
            running.activate()
            let active = await observer.waitUntil(timeout: .seconds(3)) { running.isActive }
            return active
                ? .ok(observer.describeFront())
                : .failure("\(name) didn't come to the front.", retryable: true, observation: observer.describeFront())
        }

        guard let url = AppLocator.url(forName: name) else {
            return .failure("I couldn't find an app called “\(name)” on this Mac.", retryable: false)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            let launched = await observer.waitUntil(timeout: .seconds(10)) { app.isFinishedLaunching }
            guard launched else { return .failure("\(name) is taking too long to open.", retryable: true) }
            app.activate()
            _ = await observer.waitUntil(timeout: .seconds(2)) { app.isActive }
            return .ok(observer.describeFront())
        } catch {
            return .failure("macOS couldn't open \(name): \(error.localizedDescription)", retryable: true)
        }
    }

    private func open(_ url: URL, in appName: String?) async -> ExecutionOutcome {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let host = url.host ?? url.absoluteString
        do {
            if let appName {
                guard let appURL = AppLocator.url(forName: appName) else {
                    return .failure("I couldn't find a browser called “\(appName)”.", retryable: false)
                }
                let app = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
                _ = await observer.waitUntil(timeout: .seconds(3)) { app.isActive }
            } else {
                _ = try await NSWorkspace.shared.open(url, configuration: config)
            }
            return .ok("Opened \(host). \(observer.describeFront())")
        } catch {
            return .failure("Couldn't open \(host): \(error.localizedDescription)", retryable: false)
        }
    }

    private func typeText(_ text: String) async -> ExecutionOutcome {
        if let problem = await prepareForInput() { return problem }
        let target = observer.frontmostApp?.localizedName ?? "the focused app"
        await InputController.type(text)
        try? await Task.sleep(for: .milliseconds(250))
        // Verify via Accessibility when the focused element exposes its value.
        if let value = AccessibilityController.focusedElementValue() {
            return value.contains(text)
                ? .ok("Typed \(text.count) characters into \(target); the field now contains them.")
                : .failure("The text didn't appear in \(target)'s focused field.", retryable: false)
        }
        return .ok("Typed \(text.count) characters into \(target) (field contents not readable to verify).")
    }

    private func pressKey(_ key: String, modifiers: [String]) async -> ExecutionOutcome {
        if let problem = await prepareForInput() { return problem }
        guard InputController.press(key: key, modifiers: modifiers) else {
            return .failure("Key “\(key)” isn't supported.", retryable: false)
        }
        try? await Task.sleep(for: .milliseconds(300))
        return .ok("Pressed \((modifiers + [key]).joined(separator: "+")). \(observer.describeFront())")
    }

    /// Ensures Accessibility permission and that input goes to the user's app, not Orbito.
    private func prepareForInput() async -> ExecutionOutcome? {
        guard AccessibilityController.isTrusted else {
            AccessibilityController.requestTrust()
            return .failure("Orbito needs Accessibility permission to type. Turn it on in System Settings → "
                            + "Privacy & Security → Accessibility, then try again.", retryable: false)
        }
        if observer.isSelfFrontmost {
            guard let target = observer.lastExternalApp, !target.isTerminated else {
                return .failure("Open the app you want me to type into first.", retryable: false)
            }
            target.activate()
            guard await observer.waitUntil(timeout: .seconds(2), { target.isActive }) else {
                return .failure("Couldn't switch to \(target.localizedName ?? "the target app").", retryable: false)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }
}

private extension MacAction {
    /// Action kind without user content, safe for logs.
    var kind: String {
        switch self {
        case .openApplication: "open_application"
        case .openURL: "open_url"
        case .searchWeb: "search_web"
        case .typeText: "type_text"
        case .pressKey: "press_key"
        }
    }
}

/// Finds installed applications by display name.
enum AppLocator {
    static let searchDirectories = [
        "/Applications", "/Applications/Utilities", "/System/Applications",
        "/System/Applications/Utilities", "/System/Library/CoreServices",
        NSHomeDirectory() + "/Applications",
    ]

    static func url(forName name: String) -> URL? {
        var target = name.lowercased()
        if target.hasSuffix(".app") { target.removeLast(4) }
        for dir in searchDirectories {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            if let match = items.first(where: { $0.lowercased() == target + ".app" }) {
                return URL(fileURLWithPath: dir).appendingPathComponent(match)
            }
        }
        return nil
    }
}
