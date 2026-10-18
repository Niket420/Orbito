import Foundation

/// Task state as reported by the backend. See shared/api-contract.md.
enum TaskStatus: String, Codable, Equatable {
    case pending
    case running
    case waitingForApproval = "waiting_for_approval"
    case completed
    case failed
    case cancelled

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }

    var label: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .waitingForApproval: "Needs approval"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

struct TaskDTO: Codable, Equatable {
    let taskId: String
    let instruction: String
    let status: TaskStatus
    let message: String
    let result: String?
    let error: String?
    let planner: String?
    let actions: [ActionDTO]
    let nextAction: ActionDTO?

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id", instruction, status, message, result, error, planner, actions
        case nextAction = "next_action"
    }

    /// Local stand-in shown between task creation and the first poll.
    static func placeholder(_ created: TaskCreatedDTO, instruction: String) -> TaskDTO {
        TaskDTO(taskId: created.taskId, instruction: instruction, status: created.status,
                message: created.message, result: nil, error: nil, planner: nil,
                actions: [], nextAction: nil)
    }

    var awaitingApproval: ActionDTO? {
        actions.first { $0.status == .awaitingApproval }
    }
}

struct TaskCreatedDTO: Codable {
    let taskId: String
    let status: TaskStatus
    let message: String

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id", status, message
    }
}

struct HealthDTO: Codable, Equatable {
    let status: String
    let version: String
    let llmProvider: String
    let speechProvider: String

    enum CodingKeys: String, CodingKey {
        case status, version
        case llmProvider = "llm_provider"
        case speechProvider = "speech_provider"
    }
}

struct TranscriptionDTO: Codable {
    let text: String
    let language: String?
    let provider: String
    let durationSeconds: Double

    enum CodingKeys: String, CodingKey {
        case text, language, provider
        case durationSeconds = "duration_seconds"
    }
}

struct APIErrorDTO: Codable {
    struct Body: Codable {
        let code: String
        let message: String
    }
    let error: Body
}
