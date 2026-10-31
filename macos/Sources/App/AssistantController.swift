import AppKit
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
    /// Transcript from a shortcut session, about to be sent unless cancelled.
    private(set) var pendingAutoSend: String?

    /// System-wide tap-to-talk shortcut (started by the app delegate).
    let shortcut = VoiceShortcut()
    static let autoSendDelay: Duration = .milliseconds(1200)

    private let handsFree = HandsFreeListener()
    /// Recording a command through the hands-free stream (shortcut or wake word).
    private(set) var isHandsFreeListening = false
    /// Listening for the wake word between commands (after the first shortcut tap).
    private(set) var isWakeArmed = false
    private(set) var wakeAvailable = false
    private(set) var wakePhrase = "Hey Jarvis"
    var wakeWordEnabled = UserDefaults.standard.object(forKey: "wakeWordEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(wakeWordEnabled, forKey: "wakeWordEnabled")
            if !wakeWordEnabled { stopHandsFree() }
        }
    }

    /// Agent mode: listen continuously and run every request, no wake word needed.
    private(set) var isAgentMode = false
    static let agentIdleTimeout: Duration = .seconds(300)
    /// Typing this short is approved automatically in agent mode; longer text still asks.
    static let agentAutoApproveTextLimit = 100

    /// Showing "listening" (the mic is also open while busy in agent mode, but only for "stop").
    var isListening: Bool { isRecording || (isHandsFreeListening && !isBusy) }
    var isWaitingForWakeWord: Bool { isWakeArmed && wakeAvailable && !isListening && !isAgentMode }
    private var isBusy: Bool { isTaskActive || isSubmitting || isTranscribing || pendingAutoSend != nil }

    private var sessionID = AssistantController.newSessionID()
    private var lastTaskAt: Date?
    private var agentIdleTask: Task<Void, Never>?

    private var wantsRecording = false
    private var autoSendTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var executedKeys = Set<String>()
    private var approvedActionIDs = Set<String>()
    /// Approvals already answered (the backend may not have caught up yet).
    private var answeredApprovalIDs = Set<String>()

    /// The approval waiting for an answer, if any.
    private var pendingApproval: ActionDTO? {
        task?.awaitingApproval.flatMap { answeredApprovalIDs.contains($0.actionId) ? nil : $0 }
    }

    // MARK: - Derived state

    var state: AssistantState {
        if let previewState { return previewState }
        if isListening { return .listening }
        if isTranscribing || isSubmitting || pendingAutoSend != nil { return .thinking }
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
        if isHandsFreeListening { return "I'm listening. I'll send it when you stop talking." }
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
        if handsFree.isOpen { handsFree.setMode(.idle) }
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

    /// Stops recording and transcribes. With `autoSend`, the transcript is sent after a
    /// short pause (shown in the notch) instead of waiting in the text box for review.
    func stopRecording(autoSend: Bool = false) {
        wantsRecording = false
        guard isRecording else { return }
        let samples = audio.stop()
        isRecording = false
        audioLevel = 0

        guard Double(samples.count) >= AudioCapture.sampleRate * 0.4 else {
            localError = "That was very short. Hold to talk while you speak."
            return
        }
        isTranscribing = true
        Task {
            defer {
                isTranscribing = false
                refreshHandsFreeMode()
            }
            do {
                let result = try await SpeechClient(api: backend.client).transcribe(samples: samples)
                transcriptionProvider = result.provider
                if result.text.trimmed.isEmpty {
                    localError = "I didn't catch that. Could you try again?"
                } else {
                    draft = result.text
                    if autoSend { scheduleAutoSend(result.text) }
                }
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    // MARK: - Shortcut and wake word

    func shortcutEvent(_ event: ModifierTapDetector.Event) {
        Log.app.notice("Shortcut \(String(describing: event), privacy: .public)")
        switch event {
        case .tap:
            shortcutTapped()
        case .holdStarted:
            // Hold-to-talk: start now, send on release. Agent mode is already listening.
            if !isAgentMode && !isHandsFreeListening && !isRecording { shortcutTapped() }
        case .holdEnded:
            if !isAgentMode && isHandsFreeListening { handsFree.finish() }
            else if !isAgentMode && isRecording { stopRecording(autoSend: autoSendEnabled) }
        case .holdCancelled:
            if !isAgentMode && isHandsFreeListening {
                isHandsFreeListening = false
                audioLevel = 0
                handsFree.setMode(.idle)
                refreshHandsFreeMode()
            }
        }
    }

    /// Tap the shortcut: start listening; the command is sent when you stop talking.
    /// Tapping again while listening sends it straight away.
    func shortcutTapped() {
        if isAgentMode { setAgentMode(false); return }
        if isHandsFreeListening { handsFree.finish(); return }
        if isRecording { stopRecording(autoSend: autoSendEnabled); return }  // fallback mode
        cancelPendingSend()
        guard isConnected else {
            localError = "\(AppInfo.name) is still connecting. Try again in a moment."
            return
        }
        guard !isTaskActive, !isTranscribing, !isSubmitting else { return }
        clearFinishedTask()
        if wakeWordEnabled { isWakeArmed = true }
        Task {
            do {
                try await openHandsFree()
                handsFree.setMode(.command)
                beginHandsFreeListening()
            } catch {
                // Hands-free isn't available (e.g. models not installed): plain recording,
                // stopped by the next tap.
                Log.app.notice("Hands-free unavailable, falling back to tap-to-record")
                startRecording()
            }
        }
    }

    /// Stops listening for the wake word until the shortcut is used again.
    func stopHandsFree() {
        isWakeArmed = false
        isHandsFreeListening = false
        isAgentMode = false
        agentIdleTask?.cancel()
        handsFree.close()
    }

    func setAgentMode(_ on: Bool) {
        guard on != isAgentMode else { return }
        if on {
            guard handsFree.isOpen else {
                localError = "Tap \(shortcut.preset.shortLabel) first, then turn on agent mode."
                return
            }
            isAgentMode = true
            sessionID = Self.newSessionID()
            noteAgentActivity()
            if !isHandsFreeListening && !isBusy {
                handsFree.setMode(.command)
                isHandsFreeListening = true
            }
        } else {
            isAgentMode = false
            agentIdleTask?.cancel()
            isHandsFreeListening = false
            audioLevel = 0
            handsFree.setMode(.idle)
            refreshHandsFreeMode()
        }
    }

    /// Agent mode turns itself off after a few quiet minutes.
    private func noteAgentActivity() {
        agentIdleTask?.cancel()
        agentIdleTask = Task {
            try? await Task.sleep(for: Self.agentIdleTimeout)
            guard !Task.isCancelled else { return }
            setAgentMode(false)
        }
    }

    private static func newSessionID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Tasks close together share a session, so "now close it" knows what "it" is.
    private func currentSessionID() -> String {
        if !isAgentMode, let lastTaskAt, Date().timeIntervalSince(lastTaskAt) > 300 {
            sessionID = Self.newSessionID()
        }
        lastTaskAt = Date()
        return sessionID
    }

    var autoSendEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoSendShortcut") as? Bool ?? true
    }

    func cancelPendingSend() {
        autoSendTask?.cancel()
        autoSendTask = nil
        if pendingAutoSend != nil {
            pendingAutoSend = nil
            refreshHandsFreeMode()
        }
    }

    private func openHandsFree() async throws {
        guard !handsFree.isOpen else { return }
        handsFree.onLevel = { [weak self] level in
            guard let self, self.isHandsFreeListening else { return }
            self.audioLevel = level
        }
        handsFree.onEvent = { [weak self] event in self?.handle(event) }
        try await handsFree.open(backend.client)
    }

    private func beginHandsFreeListening() {
        cancelPendingSend()
        clearFinishedTask()
        isHandsFreeListening = true
    }

    private func handle(_ event: HandsFreeListener.Event) {
        Log.app.notice("Hands-free event \(event.logName, privacy: .public)")
        switch event {
        case .ready(let wakeAvailable, let phrase):
            self.wakeAvailable = wakeAvailable
            if !phrase.isEmpty { wakePhrase = phrase.capitalized }
        case .wake:
            guard !isTaskActive, !isSubmitting, !isRecording else { handsFree.setMode(.idle); return }
            NSSound(named: "Tink")?.play()
            beginHandsFreeListening()
        case .transcribing:
            isHandsFreeListening = false
            audioLevel = 0
            isTranscribing = true
        case .transcript(let text, let provider):
            isTranscribing = false
            transcriptionProvider = provider
            if pendingApproval != nil {
                if let approved = Self.approvalAnswer(text) { respondToApproval(approved) }
                refreshHandsFreeMode()
                return
            }
            if isAgentMode {
                handleAgentSpeech(text)
                refreshHandsFreeMode()
                return
            }
            if text.trimmed.isEmpty {
                localError = "I didn't catch that. Could you try again?"
            } else {
                draft = text
                if autoSendEnabled { scheduleAutoSend(text) }
            }
            refreshHandsFreeMode()
        case .noSpeech:
            isHandsFreeListening = false
            audioLevel = 0
            refreshHandsFreeMode()
        case .error(let message):
            localError = message
            stopHandsFree()
            isTranscribing = false
        case .closed:
            isTranscribing = false
            stopHandsFree()
        }
    }

    /// In agent mode every request is sent without a wake word. While a task runs, only
    /// "stop" is acted on; noise and chit-chat are dropped here or by the planner.
    private func handleAgentSpeech(_ raw: String) {
        let text = raw.trimmed
        let words = text.lowercased().filter { $0.isLetter || $0 == " " }.trimmed
        // Whisper sometimes "hears" these in silence or noise.
        let noise: Set<String> = ["", "uh", "um", "hmm", "ok", "okay", "yeah", "thank you", "thanks",
                                  "thanks for watching", "you", "bye"]
        guard !noise.contains(words), words.count >= 2 else { return }
        noteAgentActivity()
        if isTaskActive || isSubmitting {
            let stopWords: Set<String> = ["stop", "cancel", "stop it", "never mind", "nevermind", "wait"]
            if stopWords.contains(words) { cancel() }
            return
        }
        draft = text
        scheduleAutoSend(text)
    }

    /// After each command: listen again (agent mode), wait for the wake word, pause while
    /// busy, or turn the microphone off when the wake word isn't in use.
    private func refreshHandsFreeMode() {
        guard handsFree.isOpen, !isHandsFreeListening, !isTranscribing else { return }
        if (isAgentMode || pendingApproval != nil) && !isRecording {
            // Agent mode, or waiting for a spoken "yes" / "no" to an approval.
            handsFree.setMode(.command)
            isHandsFreeListening = true
        } else if isTaskActive || isSubmitting || isRecording || pendingAutoSend != nil {
            handsFree.setMode(.idle)
        } else if isWakeArmed && wakeWordEnabled && wakeAvailable {
            handsFree.setMode(.wake)
        } else {
            handsFree.close()
        }
    }

    private func scheduleAutoSend(_ text: String) {
        autoSendTask?.cancel()
        pendingAutoSend = text
        autoSendTask = Task {
            try? await Task.sleep(for: Self.autoSendDelay)
            guard !Task.isCancelled, pendingAutoSend == text else { return }
            pendingAutoSend = nil
            submit()
        }
    }

    // MARK: - Tasks

    func submit() {
        guard canSubmit else { return }
        let instruction = draft.trimmed
        clearFinishedTask()
        isSubmitting = true
        executedKeys.removeAll()
        approvedActionIDs.removeAll()
        answeredApprovalIDs.removeAll()
        Task {
            defer { isSubmitting = false }
            do {
                let created = try await backend.client.createTask(instruction, sessionID: currentSessionID())
                task = .placeholder(created, instruction: instruction)
                startPolling(created.taskId)
            } catch {
                localError = error.localizedDescription
                refreshHandsFreeMode()
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

    /// Answering an approval out loud: true for yes, false for no, nil if unclear.
    /// "okay" and "yeah" don't count; Whisper sometimes hears them in silence.
    nonisolated static func approvalAnswer(_ text: String) -> Bool? {
        let words = " " + text.lowercased().replacingOccurrences(of: "’", with: "'")
            .filter { $0.isLetter || $0 == " " || $0 == "'" }
            .split(separator: " ").joined(separator: " ") + " "
        let no = ["no", "nope", "deny", "don't", "dont", "do not", "cancel", "stop", "reject", "never mind"]
        let yes = ["yes", "yep", "allow", "approve", "approved", "go ahead", "do it", "confirm", "sure", "proceed"]
        if no.contains(where: { words.contains(" \($0) ") }) { return false }
        if yes.contains(where: { words.contains(" \($0) ") }) { return true }
        return nil
    }

    /// Listening for a spoken answer to the approval in the notch.
    var isListeningForApproval: Bool { handsFree.isOpen && pendingApproval != nil }

    func respondToApproval(_ approved: Bool) {
        guard let task, let action = task.awaitingApproval,
              answeredApprovalIDs.insert(action.actionId).inserted else { return }
        if approved { approvedActionIDs.insert(action.actionId) }
        if !isAgentMode && isHandsFreeListening {
            // Answered with a click while listening for "yes" / "no".
            isHandsFreeListening = false
            audioLevel = 0
            handsFree.setMode(.idle)
        }
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
                    self.autoApproveIfAgent(latest)
                    if self.pendingApproval != nil { self.refreshHandsFreeMode() }
                    if latest.status.isTerminal {
                        self.refreshHandsFreeMode()
                        return
                    }
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

    /// In agent mode, short typing into the app in front doesn't need a click.
    private func autoApproveIfAgent(_ task: TaskDTO) {
        guard isAgentMode, task.status == .waitingForApproval, let action = task.awaitingApproval,
              action.type == "type_text", !approvedActionIDs.contains(action.actionId),
              case .string(let text)? = action.parameters["text"],
              text.count <= Self.agentAutoApproveTextLimit else { return }
        respondToApproval(true)
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
