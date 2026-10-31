import Foundation

/// Streams the microphone to the backend's /voice/stream, which spots the wake word,
/// notices when the user stops talking and returns the transcript. Audio is only
/// streamed over the local connection; nothing is saved.
@MainActor
final class HandsFreeListener {
    enum Mode: String {
        case idle, wake, command
    }

    enum Event {
        case ready(wakeAvailable: Bool, phrase: String)
        case wake
        case transcribing
        case transcript(String, provider: String)
        case noSpeech
        case error(String)
        case closed

        /// Event kind without user content, safe for logs.
        var logName: String {
            switch self {
            case .ready(let wake, _): "ready(wake: \(wake))"
            case .wake: "wake"
            case .transcribing: "transcribing"
            case .transcript(let text, let provider): "transcript(\(text.count) chars, \(provider))"
            case .noSpeech: "no_speech"
            case .error: "error"
            case .closed: "closed"
            }
        }
    }

    var onEvent: (Event) -> Void = { _ in }
    var onLevel: (Double) -> Void = { _ in }
    private(set) var isOpen = false

    private let audio = AudioCapture()
    private let sender = AudioSender()
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    func open(_ client: APIClient) async throws {
        guard !isOpen else { return }
        guard await AudioCapture.requestPermission() else {
            throw HandsFreeError.microphoneDenied
        }
        let socket = client.voiceStream()
        socket.resume()
        self.socket = socket
        sender.socket = socket
        let sender = self.sender
        try audio.start(keepSamples: false, onChunk: { sender.send($0) }) { [weak self] level in
            self?.onLevel(level)
        }
        isOpen = true
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
    }

    func setMode(_ mode: Mode) {
        Log.audio.notice("Hands-free mode \(mode.rawValue, privacy: .public)")
        sendControl(["mode": mode.rawValue])
    }

    /// Ends the current command now instead of waiting for a pause.
    func finish() {
        sendControl(["action": "finish"])
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        _ = audio.stop()
        receiveTask?.cancel()
        sender.socket = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func sendControl(_ payload: [String: String]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            guard let message = try? await socket.receive() else { break }
            guard case .string(let text) = message, let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            switch type {
            case "ready":
                onEvent(.ready(wakeAvailable: json["wake_available"] as? Bool ?? false,
                               phrase: json["wake_phrase"] as? String ?? ""))
            case "wake": onEvent(.wake)
            case "transcribing": onEvent(.transcribing)
            case "transcript":
                onEvent(.transcript(json["text"] as? String ?? "", provider: json["provider"] as? String ?? ""))
            case "no_speech": onEvent(.noSpeech)
            case "error": onEvent(.error(json["message"] as? String ?? "Hands-free listening stopped."))
            default: break
            }
        }
        guard isOpen, self.socket === socket else { return }
        close()
        onEvent(.closed)
    }
}

enum HandsFreeError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
    }
}

/// Converts audio-thread chunks to 16-bit PCM and sends them on the socket.
private final class AudioSender: @unchecked Sendable {
    private let lock = NSLock()
    private var _socket: URLSessionWebSocketTask?

    var socket: URLSessionWebSocketTask? {
        get { lock.withLock { _socket } }
        set { lock.withLock { _socket = newValue } }
    }

    func send(_ chunk: [Float]) {
        guard let socket else { return }
        var data = Data(capacity: chunk.count * 2)
        for sample in chunk {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        socket.send(.data(data)) { _ in }
    }
}
