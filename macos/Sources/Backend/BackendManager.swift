import Foundation
import Observation
import Security

/// Starts, supervises and stops the local Python backend, and tracks whether it is reachable.
@Observable @MainActor
final class BackendManager {
    enum Connection: Equatable {
        case connecting
        case connected
        case offline(String)

        var label: String {
            switch self {
            case .connecting: "Connecting"
            case .connected: "Connected"
            case .offline: "Offline"
            }
        }
    }

    static let defaultPort = 8765
    private static let maxLaunchAttempts = 3

    private(set) var connection: Connection = .connecting
    private(set) var health: HealthDTO?
    private(set) var backendDirectory: URL?
    private(set) var ownsProcess = false
    let port: Int
    let client: APIClient

    private var process: Process?
    private var monitorTask: Task<Void, Never>?
    private var launchAttempts = 0

    init() {
        let stored = UserDefaults.standard.integer(forKey: "backendPort")
        port = (1024...65535).contains(stored) ? stored : Self.defaultPort
        client = APIClient(port: port, token: TokenStore.loadOrCreate())
        backendDirectory = Self.locateBackend()
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkHealth()
                try? await Task.sleep(for: self.connection == .connected ? .seconds(3) : .seconds(1))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        if let process, process.isRunning {
            Log.backend.info("Stopping backend (pid \(process.processIdentifier))")
            process.terminate()
        }
        process = nil
        ownsProcess = false
    }

    func restart() {
        stop()
        launchAttempts = 0
        connection = .connecting
        health = nil
        // Give uvicorn a moment to release the port before relaunching.
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            start()
        }
    }

    private func checkHealth() async {
        if let health = try? await client.health() {
            self.health = health
            connection = .connected
            launchAttempts = 0
            return
        }
        health = nil
        if process?.isRunning == true {
            connection = .connecting  // still starting up (first run may download the speech model)
        } else if launchAttempts < Self.maxLaunchAttempts {
            launch()
        } else if case .offline = connection {
            // keep the existing explanation
        } else {
            connection = .offline("The backend couldn't be started. See backend.log in Settings.")
        }
    }

    private func launch() {
        launchAttempts += 1
        guard let dir = backendDirectory ?? Self.locateBackend() else {
            launchAttempts = Self.maxLaunchAttempts
            connection = .offline("Backend folder not found. Set ORBITO_BACKEND_DIR or start it with scripts/dev.sh.")
            return
        }
        backendDirectory = dir

        let process = Process()
        let venvPython = dir.appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            process.executableURL = venvPython
            process.arguments = ["-m", "app.main"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-m", "app.main"]
        }
        process.currentDirectoryURL = dir

        var env = ProcessInfo.processInfo.environment
        env["ORBITO_API_TOKEN"] = TokenStore.loadOrCreate()
        env["ORBITO_PORT"] = String(port)
        env["PYTHONUNBUFFERED"] = "1"
        env["NEEDLE_TELEMETRY"] = "0"
        // Lets the backend exit on its own if this app crashes or is force-quit.
        env["ORBITO_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        process.environment = env

        if let log = Self.openLogFile() {
            process.standardOutput = log
            process.standardError = log
        }
        process.terminationHandler = { proc in
            Log.backend.notice("Backend exited with status \(proc.terminationStatus)")
        }

        do {
            try process.run()
            self.process = process
            ownsProcess = true
            connection = .connecting
            Log.backend.info("Launched backend (pid \(process.processIdentifier)), attempt \(self.launchAttempts)")
        } catch {
            Log.backend.error("Failed to launch backend: \(error.localizedDescription, privacy: .public)")
            connection = .offline("Couldn't launch Python: \(error.localizedDescription)")
        }
    }

    private static func openLogFile() -> FileHandle? {
        let url = AppPaths.backendLog
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    /// Finds the `backend` folder from the env override, the bundled copy, or a parent of the
    /// executable / working directory. A folder with a ready `.venv` wins over one without.
    static func locateBackend() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["ORBITO_BACKEND_DIR"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("backend") {
            candidates.append(bundled)
        }
        let starts = [Bundle.main.executableURL?.deletingLastPathComponent(),
                      URL(fileURLWithPath: fm.currentDirectoryPath)].compactMap { $0 }
        for start in starts {
            var dir = start
            for _ in 0..<8 {
                candidates.append(dir.appendingPathComponent("backend").standardizedFileURL)
                dir.deleteLastPathComponent()
            }
        }

        let backends = candidates.filter { fm.fileExists(atPath: $0.appendingPathComponent("app/main.py").path) }
        return backends.first { fm.isExecutableFile(atPath: $0.appendingPathComponent(".venv/bin/python").path) }
            ?? backends.first
    }
}

/// The API token shared with the backend, stored in a 0600 file in Application Support.
enum TokenStore {
    static func loadOrCreate() -> String {
        let url = AppPaths.tokenFile
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmed, !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("Secure random generator unavailable")
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return token
    }
}
