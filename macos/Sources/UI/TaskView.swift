import SwiftUI

/// Current task: instruction, status, step-by-step progress, approval and result.
struct TaskView: View {
    @Environment(AssistantController.self) private var assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Current task")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if let task = assistant.task {
                    StatusChip(status: task.status)
                }
            }

            if let task = assistant.task {
                TaskDetails(task: task)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                EmptyTaskState()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 22)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: assistant.task)
    }
}

private struct TaskDetails: View {
    @Environment(AssistantController.self) private var assistant
    let task: TaskDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("“\(task.instruction)”")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if task.actions.isEmpty && !task.status.isTerminal {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(task.message)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondaryInk)
                }
            }

            if !task.actions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(task.actions.enumerated()), id: \.element.id) { index, action in
                        StepRow(index: index + 1, action: action,
                                running: action.id == task.nextAction?.id)
                    }
                }
            }

            if let pending = task.awaitingApproval, task.status == .waitingForApproval {
                ApprovalBanner(action: pending)
            }

            switch task.status {
            case .completed:
                ResultBox(icon: "checkmark.seal.fill", tint: Theme.green, title: "Done",
                          text: task.result ?? "Finished every step.")
            case .failed:
                ResultBox(icon: "exclamationmark.bubble.fill", tint: Theme.rose, title: "Couldn't finish",
                          text: task.error ?? task.message) {
                    Button("Try again", systemImage: "arrow.clockwise", action: assistant.retry)
                        .buttonStyle(SoftButtonStyle(tint: Theme.rose))
                        .disabled(!assistant.isConnected)
                }
            case .cancelled:
                ResultBox(icon: "stop.circle.fill", tint: Theme.secondaryInk, title: "Stopped", text: task.message)
            default:
                EmptyView()
            }

            if let planner = task.planner {
                Text(planner == "mock" ? "Planned by the mock planner" : "Planned by \(planner.capitalized)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryInk.opacity(0.8))
            }
        }
    }
}

private struct StepRow: View {
    let index: Int
    let action: ActionDTO
    let running: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(action.description)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(action.status == .skipped ? Theme.secondaryInk : Theme.ink)
                    .strikethrough(action.status == .skipped, color: Theme.secondaryInk)
                if let error = action.error, action.status == .failed || action.attempt > 1 {
                    Text(error)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.rose)
                } else if let observation = action.observation, action.status == .succeeded {
                    Text(observation)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if action.requiresApproval {
                Image(systemName: "hand.raised")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                    .help("Needs your approval")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(running ? Theme.blue.opacity(0.07) : Theme.background)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(index): \(action.description), \(action.status.rawValue)")
    }

    @ViewBuilder private var icon: some View {
        switch action.status {
        case .ready:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.rose)
        case .awaitingApproval:
            Image(systemName: "hand.raised.circle.fill").foregroundStyle(Theme.amber)
                .symbolEffect(.pulse)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(Theme.secondaryInk.opacity(0.6))
        case .queued:
            Text("\(index)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1.5))
        }
    }
}

private struct ApprovalBanner: View {
    @Environment(AssistantController.self) private var assistant
    let action: ActionDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Allow this step?", systemImage: "hand.raised.fill")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.amber)
            Text("\(AppInfo.name) wants to \(action.description.prefix(1).lowercased() + action.description.dropFirst()) in the app you were using.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Deny") { assistant.respondToApproval(false) }
                    .buttonStyle(SoftButtonStyle(tint: Theme.secondaryInk))
                Button("Approve") { assistant.respondToApproval(true) }
                    .buttonStyle(GradientButtonStyle())
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.amber.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.amber.opacity(0.35), lineWidth: 1))
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
}

private struct ResultBox<Accessory: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let text: String
    @ViewBuilder var accessory: () -> Accessory

    init(icon: String, tint: Color, title: String, text: String,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.text = text
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, value: title)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                    Text(text)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            HStack { Spacer(); accessory() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(0.09)))
    }
}

struct StatusChip: View {
    let status: TaskStatus

    private var style: (Color, String) {
        switch status {
        case .pending: (Theme.secondaryInk, "clock")
        case .running: (Theme.blue, "bolt.fill")
        case .waitingForApproval: (Theme.amber, "hand.raised.fill")
        case .completed: (Theme.green, "checkmark")
        case .failed: (Theme.rose, "xmark")
        case .cancelled: (Theme.secondaryInk, "stop.fill")
        }
    }

    var body: some View {
        Label(status.label, systemImage: style.1)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(style.0)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(style.0.opacity(0.12)))
            .contentTransition(.opacity)
            .animation(.easeInOut, value: status)
    }
}

private struct EmptyTaskState: View {
    @Environment(AssistantController.self) private var assistant
    private let examples = [
        "Open Safari and search for AI news",
        "Open Notes",
        "Go to apple.com",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.purple.opacity(0.08)))
                Text("Your task's progress will show up here, step by step.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Try saying")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.secondaryInk)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button { assistant.useExample(example) } label: {
                        Label(example, systemImage: "quote.opening")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(SoftButtonStyle(tint: Theme.purple))
                }
            }
        }
    }
}
