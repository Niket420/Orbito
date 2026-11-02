import CoreGraphics
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
        #expect(NotchPhase.listening.isInteractive)  // the agent mode switch
        #expect(!NotchPhase.working("x").isInteractive)
        #expect(!NotchPhase.done("x").isInteractive)
    }

    @Test func finishedPhasesAutoDismiss() {
        #expect(NotchPhase.done("x").dismissKey != nil)
        #expect(NotchPhase.failed("x").dismissKey != nil)
        #expect(NotchPhase.working("x").dismissKey == nil)
    }

    @MainActor @Test func layoutHidesInsideTheNotchAndGrowsOutOfIt() {
        let notch = NotchMetrics(notchWidth: 185, notchHeight: 32)
        let hidden = NotchLayout.size(for: .hidden, metrics: notch)
        let listening = NotchLayout.size(for: .listening, metrics: notch)
        let approval = NotchLayout.size(for: .approval(action(.awaitingApproval)), metrics: notch)
        #expect(hidden.height == 32)
        #expect(hidden.width == 185 + NotchLayout.flare * 2)       // exactly covers the notch
        // Content starts below the camera notch so the hardware never hides it.
        #expect(NotchLayout.contentTop(notch) == 32)
        #expect(listening.height > 32 + NotchLayout.rowHeight && listening.width > hidden.width)
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
    private let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]
    typealias Event = ModifierTapDetector.Event

    /// Feeds (time, flags) samples; returns the events in order.
    private func events(_ samples: [(TimeInterval, CGEventFlags)], keyDownAt: TimeInterval = -100) -> [Event] {
        var detector = ModifierTapDetector(target: ctrlOpt)
        return samples.compactMap { time, flags in
            // Before the key press, the last key press was long ago.
            detector.update(flags: flags, now: time, secondsSinceKeyDown: time >= keyDownAt ? time - keyDownAt : 100)
        }
    }

    @Test func quickTapFires() {
        #expect(events([(0, .maskControl), (0.05, ctrlOpt), (0.2, .maskAlternate), (0.25, [])]) == [.tap])
    }

    @Test func holdingIsHoldToTalk() {
        #expect(events([(0, ctrlOpt), (0.4, ctrlOpt), (3, ctrlOpt), (3.1, [])]) == [.holdStarted, .holdEnded])
    }

    @Test func extraModifierOrKeySpoilsIt() {
        // ⌃⌥⌘ chord
        #expect(events([(0, ctrlOpt), (0.1, [.maskControl, .maskAlternate, .maskCommand]), (0.2, [])]).isEmpty)
        // ⌃⌥ + a key (e.g. ⌃⌥Space)
        #expect(events([(0, ctrlOpt), (0.2, [])], keyDownAt: 0.1).isEmpty)
        // only one of the two keys
        #expect(events([(0, .maskControl), (0.1, [])]).isEmpty)
        // a key pressed during a hold cancels it
        #expect(events([(0, ctrlOpt), (0.4, ctrlOpt), (1, ctrlOpt), (1.2, [])], keyDownAt: 0.9)
                == [.holdStarted, .holdCancelled])
    }

    @Test func capsLockIsIgnored() {
        #expect(events([(0, [.maskControl, .maskAlternate, .maskAlphaShift]), (0.1, .maskAlphaShift)]) == [.tap])
    }
}

@Suite("Voice approval")
struct VoiceApprovalTests {
    @Test func yesAndNo() {
        for text in ["Yes.", "yes please", "Allow", "Go ahead", "Do it!", "Yep, approve it", "sure"] {
            #expect(AssistantController.approvalAnswer(text) == true, "\(text)")
        }
        for text in ["No.", "nope", "Deny", "Don't do it", "don’t", "Cancel that", "no, stop"] {
            #expect(AssistantController.approvalAnswer(text) == false, "\(text)")
        }
    }

    @Test func unclearOrSilenceHallucinationsDontCount() {
        for text in ["", "okay", "Yeah", "thank you", "open Safari", "yesterday", "know", "nobody"] {
            #expect(AssistantController.approvalAnswer(text) == nil, "\(text)")
        }
    }
}

@Suite("Agent actions")
struct AgentActionTests {
    private func dto(_ type: String, _ parameters: [String: JSONValue]) -> ActionDTO {
        ActionDTO(actionId: "a1", type: type, parameters: parameters, description: "", requiresApproval: false,
                  status: .ready, attempt: 1, observation: nil, error: nil)
    }

    @Test func closeAndScrollValidate() throws {
        #expect(try MacAction(dto("close_application", ["application_name": .string("Calculator")]))
                == .closeApplication(name: "Calculator"))
        #expect(try MacAction(dto("scroll", ["direction": .string("down"), "amount": .number(10)]))
                == .scroll(direction: "down", lines: 10))
        #expect(try MacAction(dto("scroll", ["direction": .string("up")])) == .scroll(direction: "up", lines: 5))
        #expect(!(try MacAction(dto("close_application", ["application_name": .string("Notes")]))).requiresApproval)
    }

    @Test func badScrollIsRejected() {
        #expect(throws: ActionValidationError.self) { try MacAction(dto("scroll", ["direction": .string("sideways")])) }
        #expect(throws: ActionValidationError.self) {
            try MacAction(dto("scroll", ["direction": .string("down"), "amount": .number(999)]))
        }
    }
}

@Suite("Full-control actions")
struct FullControlActionTests {
    private func action(_ type: String, _ parameters: [String: JSONValue] = [:]) throws -> MacAction {
        try MacAction(ActionDTO(actionId: "a1", type: type, parameters: parameters, description: "",
                                requiresApproval: false, status: .ready, attempt: 1, observation: nil, error: nil))
    }

    @Test func parsesTheNewActions() throws {
        #expect(try action("switch_application") == .switchApplication(name: nil))
        #expect(try action("window_control", ["operation": .string("left_half")]) == .windowControl("left_half"))
        #expect(try action("app_command", ["command": .string("new_tab")]) == .appCommand("new_tab"))
        #expect(try action("ask", ["question": .string("what's this?"), "source": .string("screen")])
                == .ask(question: "what's this?", source: "screen"))
        #expect(try action("take_screenshot") == .takeScreenshot(area: "full", destination: "file"))
        #expect(try action("system_control", ["control": .string("set_volume"), "value": .number(40)])
                == .systemControl("set_volume", value: 40))
        #expect(try action("create_reminder", ["title": .string("tea"), "in_minutes": .number(10)])
                == .createReminder(title: "tea", inMinutes: 10, due: nil))
        #expect(try action("compose_email", ["to": .array([.string("a@b.com")])])
                == .composeEmail(to: ["a@b.com"], subject: nil, body: nil))
        #expect(try action("trash_selected_files") == .trashSelectedFiles)
    }

    @Test func riskyStepsNeedApproval() throws {
        #expect(try action("click_element", ["target": .string("Delete account")]).requiresApproval)
        #expect(!(try action("click_element", ["target": .string("Sign in")]).requiresApproval))
        #expect(try action("system_control", ["control": .string("lock_screen")]).requiresApproval)
        #expect(!(try action("system_control", ["control": .string("mute")]).requiresApproval))
        #expect(try action("trash_selected_files").requiresApproval)
        #expect(try action("force_quit_application", ["application_name": .string("Xcode")]).requiresApproval)
        #expect(try action("create_event", ["title": .string("x"), "start": .string("2026-05-01T18:30")]).requiresApproval)
    }

    @Test func rejectsBadValues() {
        let bad: [(String, [String: JSONValue])] = [
            ("app_command", ["command": .string("quit")]),
            ("window_control", ["operation": .string("explode")]),
            ("open_location", ["location": .string("documents"), "subfolder": .string("../../etc")]),
            ("create_folder", ["name": .string(".hidden")]),
            ("create_reminder", ["title": .string("x"), "due": .string("tomorrow 6pm")]),
            ("compose_email", ["to": .array([.string("not an email")])]),
            ("system_control", ["control": .string("shutdown")]),
            ("trash_selected_files", ["path": .string("/")]),
        ]
        for (type, parameters) in bad {
            #expect(throws: ActionValidationError.self, "\(type)") { try action(type, parameters) }
        }
    }

    @Test func helpers() {
        #expect(Places.subfolder("../..", in: URL(fileURLWithPath: NSHomeDirectory())) == nil)
        #expect(Places.mailtoURL(to: ["a@b.com"], subject: "Hi there", body: nil)?.absoluteString
                == "mailto:a@b.com?subject=Hi%20there")
        #expect(Places.mediaSearchURL("lo fi", app: "youtube").absoluteString
                == "https://www.youtube.com/results?search_query=lo%20fi")
        #expect(MacAction.appCommands.count == 21)
        #expect(Places.settingsPanes.count == MacAction.settingsPanes.count)
        #expect(LocalTime.date("2026-05-01T18:30") != nil)
    }
}
