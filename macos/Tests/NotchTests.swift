import Foundation
import Testing
@testable import Orbito

private func task(_ status: TaskStatus, actions: [ActionDTO] = [], result: String? = nil, error: String? = nil) -> TaskDTO {
    TaskDTO(taskId: "t", instruction: "open chrome", status: status, message: "msg", result: result,
            error: error, planner: "groq", actions: actions, nextAction: nil)
}

private func action(_ status: ActionStatus, _ description: String = "Open Google Chrome") -> ActionDTO {
    ActionDTO(actionId: "a1", type: "open_application", parameters: [:], description: description,
              requiresApproval: false, status: status, attempt: 1, observation: nil, error: nil)
}

private func phase(isRecording: Bool = false, isTranscribing: Bool = false, pendingSend: String? = nil,
                   isSubmitting: Bool = false, task: TaskDTO? = nil, localError: String? = nil) -> NotchPhase {
    NotchPhase.derive(isRecording: isRecording, isTranscribing: isTranscribing, pendingSend: pendingSend,
                      isSubmitting: isSubmitting, task: task, localError: localError)
}

@Suite("Notch")
struct NotchTests {
    @Test func idleIsHidden() {
        #expect(phase() == .hidden)
        #expect(phase(task: task(.cancelled)) == .hidden)
    }

    @Test func voiceSessionPhases() {
        #expect(phase(isRecording: true) == .listening)
        #expect(phase(isTranscribing: true) == .transcribing)
        #expect(phase(pendingSend: "open chrome") == .confirming("open chrome"))
        #expect(phase(isSubmitting: true) == .thinking)
    }

    @Test func taskPhases() {
        #expect(phase(task: task(.pending)) == .thinking)
        #expect(phase(task: task(.running)) == .thinking)  // still planning
        #expect(phase(task: task(.running, actions: [action(.ready)])) == .working("Open Google Chrome"))
        #expect(phase(task: task(.waitingForApproval, actions: [action(.awaitingApproval, "Type “hi”")]))
                == .approval(action(.awaitingApproval, "Type “hi”")))
        #expect(phase(task: task(.completed, result: "Opened Chrome")) == .done("Opened Chrome"))
        #expect(phase(task: task(.failed, error: "No such app")) == .failed("No such app"))
    }

    @Test func recordingWinsOverAnOldTask() {
        #expect(phase(isRecording: true, task: task(.completed, result: "x")) == .listening)
    }

    @Test func onlyButtonPhasesTakeClicks() {
        #expect(NotchPhase.confirming("x").isInteractive)
        #expect(NotchPhase.approval(action(.awaitingApproval)).isInteractive)
        #expect(!NotchPhase.listening.isInteractive)
        #expect(!NotchPhase.done("x").isInteractive)
    }

    @Test func finishedPhasesAutoDismiss() {
        #expect(NotchPhase.done("x").dismissKey != nil)
        #expect(NotchPhase.failed("x").dismissKey != nil)
        #expect(NotchPhase.working("x").dismissKey == nil)
    }

    @Test func layoutHidesInsideTheNotchAndGrowsOutOfIt() {
        let notch = NotchMetrics(notchWidth: 185, notchHeight: 32)
        let hidden = NotchLayout.size(for: .hidden, metrics: notch)
        let listening = NotchLayout.size(for: .listening, metrics: notch)
        let approval = NotchLayout.size(for: .approval(action(.awaitingApproval)), metrics: notch)
        #expect(hidden.height == 32)
        #expect(hidden.width == 185 + NotchLayout.flare * 2)       // exactly covers the notch
        // Content starts below the camera notch so the hardware never hides it.
        #expect(NotchLayout.contentTop(notch) == 32)
        #expect(listening.height == 32 + NotchLayout.rowHeight && listening.width > hidden.width)
        #expect(approval.height > listening.height)
        #expect(approval.width <= NotchWindowController.canvas.width)
        #expect(approval.height <= NotchWindowController.canvas.height)
        // Displays without a notch: fully hidden when idle, content from the top.
        let plain = NotchMetrics(notchWidth: 0, notchHeight: 24)
        #expect(NotchLayout.size(for: .hidden, metrics: plain).height == 0)
        #expect(NotchLayout.contentTop(plain) == 0)
    }
}

@Suite("Voice shortcut")
struct ShortcutTests {
    private func combo(_ modifiers: Int) -> KeyCombo {
        KeyCombo(keyCode: 49, modifiers: UInt32(modifiers), keyName: "Space")
    }

    @Test func optionOnlyShortcutsAreRejected() {
        // macOS 15 registers these without error but never delivers them.
        #expect(combo(0x0800).problem != nil)            // ⌥
        #expect(combo(0x0800 | 0x0200).problem != nil)   // ⇧⌥
        #expect(combo(0).problem != nil)                 // no modifier
    }

    @Test func commandOrControlShortcutsAreAllowed() {
        #expect(KeyCombo.defaultCombo.problem == nil)
        #expect(combo(0x0100 | 0x0200).problem == nil)   // ⇧⌘
        #expect(combo(0x1000).problem == nil)            // ⌃
    }

    @Test func labelsReadInMacOrder() {
        #expect(KeyCombo.defaultCombo.label == "⌃⌥ Space")
        #expect(combo(0x0100 | 0x0200 | 0x1000).label == "⌃⇧⌘ Space")
    }
}
