import Foundation

struct APIError: LocalizedError, Equatable {
    enum Kind: Equatable { case offline, unauthorized, conflict, server, decoding }

    let kind: Kind
    let message: String
    var errorDescription: String? { message }
}

struct ActionResultReport: Encodable {
    let attempt: Int
    let success: Bool
    let observation: String?
    let error: String?
    let retryable: Bool
}

/// Typed HTTP client for the local backend. All calls are async and never block the UI.
final class APIClient: Sendable {
    let baseURL: URL
    private let token: String
    private let session: URLSession

    init(port: Int, token: String) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func health() async throws -> HealthDTO {
        try await send("GET", "/health", timeout: 2)
    }

    func createTask(_ instruction: String) async throws -> TaskCreatedDTO {
        try await send("POST", "/tasks", json: ["instruction": instruction])
    }

    func task(_ id: String) async throws -> TaskDTO {
        try await send("GET", "/tasks/\(id)")
    }

    func cancelTask(_ id: String) async throws -> TaskDTO {
        try await send("POST", "/tasks/\(id)/cancel")
    }

    func setApproval(_ id: String, approved: Bool) async throws -> TaskDTO {
        try await send("POST", "/tasks/\(id)/approval", json: ["approved": approved])
    }

    func reportResult(_ taskID: String, action: ActionDTO, outcome: ExecutionOutcome) async throws -> TaskDTO {
        let report = ActionResultReport(attempt: action.attempt, success: outcome.success,
                                        observation: outcome.observation.map { String($0.prefix(500)) },
                                        error: outcome.error.map { String($0.prefix(500)) },
                                        retryable: outcome.retryable)
        return try await send("POST", "/tasks/\(taskID)/actions/\(action.actionId)/result",
                              body: try JSONEncoder().encode(report))
    }

    func transcribe(wav: Data) async throws -> TranscriptionDTO {
        try await send("POST", "/speech/transcribe", body: wav, contentType: "audio/wav", timeout: 60)
    }

    // MARK: - Transport

    private func send<T: Decodable>(_ method: String, _ path: String, json: [String: Any]) async throws -> T {
        try await send(method, path, body: try JSONSerialization.data(withJSONObject: json))
    }

    private func send<T: Decodable>(
        _ method: String, _ path: String, body: Data? = nil,
        contentType: String = "application/json", timeout: TimeInterval = 10
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError(kind: .offline, message: "Can't reach the Orbito backend.")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(APIErrorDTO.self, from: data))?.error.message
                ?? "The backend returned an error (\(status))."
            let kind: APIError.Kind = switch status {
            case 401: .unauthorized
            case 409: .conflict
            default: .server
            }
            throw APIError(kind: kind, message: kind == .unauthorized
                           ? "The backend rejected Orbito's access token. Restart the backend from Settings."
                           : message)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.backend.error("Decoding \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw APIError(kind: .decoding, message: "The backend sent an unexpected response.")
        }
    }
}
