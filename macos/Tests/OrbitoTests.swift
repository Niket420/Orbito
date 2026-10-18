import Foundation
import Testing
@testable import Orbito

private func action(_ type: String, _ parameters: [String: JSONValue], approval: Bool = false) -> ActionDTO {
    ActionDTO(actionId: "abc123def456", type: type, parameters: parameters, description: "", requiresApproval: approval,
              status: .ready, attempt: 1, observation: nil, error: nil)
}

@Suite("MacAction validation")
struct MacActionTests {
    @Test func acceptsAllowlistedActions() throws {
        #expect(try MacAction(action("open_application", ["application_name": .string("Safari")])) == .openApplication(name: "Safari"))
        #expect(try MacAction(action("search_web", ["query": .string("AI news"), "application_name": .string("Safari")]))
                == .searchWeb(query: "AI news", app: "Safari"))
        #expect(try MacAction(action("open_url", ["url": .string("https://apple.com")])) == .openURL(URL(string: "https://apple.com")!, app: nil))
        #expect(try MacAction(action("press_key", ["key": .string("T"), "modifiers": .array([.string("command")])]))
                == .pressKey(key: "t", modifiers: ["command"]))
    }

    @Test(arguments: [
        action("run_shell", ["command": .string("rm -rf ~")]),
        action("open_application", [:]),
        action("open_application", ["application_name": .string("Safari; rm -rf /")]),
        action("open_application", ["application_name": .string("Safari"), "extra": .bool(true)]),
        action("open_url", ["url": .string("file:///etc/passwd")]),
        action("open_url", ["url": .string("javascript:alert(1)")]),
        action("press_key", ["key": .string("q"), "modifiers": .array([.string("command")])]),
        action("press_key", ["key": .string("f13")]),
        action("type_text", ["text": .string(String(repeating: "x", count: 501))]),
        action("type_text", ["text": .number(4)]),
    ])
    func rejectsUnsafeOrMalformed(_ dto: ActionDTO) {
        #expect(throws: ActionValidationError.self) { try MacAction(dto) }
    }

    @Test func inputActionsAlwaysNeedApproval() throws {
        // Even if the backend claims no approval is needed, the app's own policy applies.
        let typing = try MacAction(action("type_text", ["text": .string("hi")], approval: false))
        #expect(typing.requiresApproval)
        #expect(try !MacAction(action("open_application", ["application_name": .string("Notes")])).requiresApproval)
    }
}

@Suite("Wire format")
struct WireFormatTests {
    @Test func decodesTaskResponse() throws {
        let json = """
        {"task_id":"6f9fb9d3c22e48b1be63951278274a1c","instruction":"Open Safari","status":"running",
         "message":"Step 1 of 1: Open Safari","result":null,"error":null,"planner":"mock",
         "actions":[{"action_id":"f6d930928388","type":"open_application","parameters":{"application_name":"Safari"},
           "description":"Open Safari","requires_approval":false,"status":"ready","attempt":1,"observation":null,"error":null}],
         "next_action":{"action_id":"f6d930928388","type":"open_application","parameters":{"application_name":"Safari"},
           "description":"Open Safari","requires_approval":false,"status":"ready","attempt":1,"observation":null,"error":null},
         "created_at":"2026-10-18T11:36:26Z","updated_at":"2026-10-18T11:36:26Z"}
        """
        let task = try JSONDecoder().decode(TaskDTO.self, from: Data(json.utf8))
        #expect(task.status == .running)
        #expect(task.nextAction?.parameters["application_name"] == .string("Safari"))
        #expect(try MacAction(task.nextAction!) == .openApplication(name: "Safari"))
    }

    @Test func wavHeaderIs16kMonoPCM() {
        let wav = SpeechClient.wavData(samples: [0, 0.5, -0.5, 1], sampleRate: 16_000)
        #expect(wav.count == 44 + 8)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let channels = wav[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        #expect(UInt32(littleEndian: rate) == 16_000)
        #expect(UInt16(littleEndian: channels) == 1)
    }

    @Test func searchURLIsEncoded() {
        #expect(ActionExecutor.searchURL(for: "AI news & more").absoluteString
                == "https://www.google.com/search?q=AI%20news%20%26%20more")
    }
}
