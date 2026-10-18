import Foundation
import Observation

/// The assistant's visual state, derived from recording, backend and task status.
enum AssistantState: String, CaseIterable, Identifiable {
    case idle, listening, thinking, executing, waitingForApproval, completed, error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "Hi! How can I help?"
        case .listening: "I'm listening…"
        case .thinking: "Thinking…"
        case .executing: "Working on it…"
        case .waitingForApproval: "Can I go ahead?"
        case .completed: "All done!"
        case .error: "Hmm, that didn't work"
        }
    }

    var previewLabel: String {
        switch self {
        case .waitingForApproval: "Waiting for approval"
        default: rawValue.capitalized
        }
    }
}

/// Coordinates the microphone, the backend task lifecycle and local action execution.
@Observable @MainActor
final class AssistantController {
    let backend = BackendManager()
    let executor = ActionExecutor()
    private let audio = AudioCapture()

    var draft = ""
    /// Overrides the bot's state from Settings, to preview every animation.
    var previewState: AssistantState?

    private(set) var isRecording = false
    private(set) var isTranscribing = false
    private(set) var isSubmitting = false
    private(set) var isExecutingAction = false
    private(set) var audioLevel: Double = 0
    private(set) var transcriptionProvider: String?
    private(set) var task: TaskDTO?
    private(set) var localError: String?

    private var wantsRecording = false
    private var pollTask: Task<Void, Never>?
    private var executedKeys = Set<String>()
    private var approvedActionIDs = Set<String>()

    // MARK: - Derived state

    var state: AssistantState {
        if let previewState { return previewState }
        if isRecording { return .listening }
        if isTranscribing || isSubmitting { return .thinking }
        if localError != nil { return .error }
        guard let task else { return .idle }
        switch task.status {
        case .pending: return .thinking
        case .running: return task.nextAction != nil || isExecutingAction ? .executing : .thinking
        case .waitingForApproval: return .waitingForApproval
        case .completed: return .completed
        case .failed: return .error
        case .cancelled: return .idle
        }
    }

    var statusDetail: String {
        if isRecording { return "Release the button when you're done speaking." }
        if isTranscribing { return "Turning your voice into text…" }
        if isSubmitting { return "Sending your instruction…" }
        if let localError { return localError }
        if let task {
            switch task.status {
            case .completed: return task.result ?? task.message
            case .failed: return task.error ?? task.message
            default: return task.message
            }
        }
        switch backend.connection {
        case .connected: return "Hold the mic button and say what you'd like me to do."
        case .connecting: return "Starting up my brain…"
        case .offline(let reason): return reason
        }
    }

    var isTaskActive: Bool { task.map { !$0.status.isTerminal } ?? false }
    var isConnected: Bool { backend.connection == .connected }
    var canRecord: Bool { isConnected && !isTaskActive && !isTranscribing && !isSubmitting }
    var canSubmit: Bool { canRecord && !isRecording && !draft.trimmed.isEmpty }

    // MARK: - Voice

    func startRecording() {
        guard canRecord, !isRecording else { return }
        wantsRecording = true
        clearFinishedTask()
        Task {
            guard await AudioCapture.requestPermission() else {
                localError = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
                return
            }
            guard wantsRecording else { return }  // released before permission resolved
            do {
                try audio.start { [weak self] level in self?.audioLevel = level }
                isRecording = true
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        wantsRecording = false
        guard isRecording else { return }
        let samples = audio.stop()
        isRecording = false
        audioLevel = 0

        guard Double(samples.count) >= AudioCapture.sampleRate * 0.4 else {
            localError = "That was very short. Hold the mic button while you speak."
            return
        }
        isTranscribing = true
        Task {
            defer { isTranscribing = false }
            do {
                let result = try await SpeechClient(api: backend.client).transcribe(samples: samples)
                transcriptionProvider = result.provider
                if result.text.trimmed.isEmpty {
                    localError = "I didn't catch that. Could you try again?"
                } else {
                    draft = result.text
                }
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    // MARK: - Tasks

    func submit() {
        guard canSubmit else { return }
        let instruction = draft.trimmed
        clearFinishedTask()
        isSubmitting = true
        executedKeys.removeAll()
        approvedActionIDs.removeAll()
        Task {
            defer { isSubmitting = false }
            do {
                let created = try await backend.client.createTask(instruction)
                task = .placeholder(created, instruction: instruction)
                startPolling(created.taskId)
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    func cancel() {
        if isRecording { stopRecording() }
        guard let id = task?.taskId, isTaskActive else { return }
        Task {
            do { task = try await backend.client.cancelTask(id) } catch { localError = error.localizedDescription }
        }
    }

    func respondToApproval(_ approved: Bool) {
        guard let task, let action = task.awaitingApproval else { return }
        if approved { approvedActionIDs.insert(action.actionId) }
        Task {
            do { self.task = try await backend.client.setApproval(task.taskId, approved: approved) }
            catch { localError = error.localizedDescription }
        }
    }

    func retry() {
        guard let instruction = task?.instruction else { return }
        draft = instruction
        submit()
    }

    func useExample(_ text: String) {
        clearFinishedTask()
        draft = text
    }

    func clearFinishedTask() {
        localError = nil
        if let task, task.status.isTerminal { self.task = nil }
    }

    // MARK: - Polling and execution

    private func startPolling(_ id: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let latest = try await self.backend.client.task(id)
                    failures = 0
                    self.task = latest
                    if latest.status.isTerminal { return }
                    if let action = latest.nextAction {
                        await self.run(action, taskID: id)
                        continue
                    }
                } catch {
                    failures += 1
                    if failures >= 10 {
                        self.localError = error.localizedDescription
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func run(_ dto: ActionDTO, taskID: String) async {
        // Each (action, attempt) pair runs at most once, even if polled again.
        guard executedKeys.insert("\(dto.actionId)#\(dto.attempt)").inserted else { return }
        isExecutingAction = true
        defer { isExecutingAction = false }

        let outcome: ExecutionOutcome
        do {
            let action = try MacAction(dto)
            if action.requiresApproval && !approvedActionIDs.contains(dto.actionId) {
                outcome = .failure("This step needs your approval in \(AppInfo.name) first.", retryable: false)
            } else {
                outcome = await executor.execute(action)
            }
        } catch {
            outcome = .failure(error.localizedDescription, retryable: false)
        }

        for attempt in 1...3 {
            do {
                task = try await backend.client.reportResult(taskID, action: dto, outcome: outcome)
                return
            } catch let error as APIError where error.kind == .conflict {
                return  // the task moved on (e.g. cancelled); the next poll picks it up
            } catch {
                try? await Task.sleep(for: .milliseconds(300 * attempt))
            }
        }
    }
}
