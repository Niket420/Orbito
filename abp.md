Voice-Controlled macOS Assistant — Architecture

1. Project Goal

Build a native macOS application that allows users to control their Mac through natural-language voice instructions.

Examples:

* “Open Safari and search for the latest AI news.”
* “Open VS Code and show me the current project.”
* “Find a file and move it to another folder.”
* “Open the terminal and execute this command.”

The application should interpret instructions, plan actions, execute them, observe results, and recover from failures when possible.

Initial platform: macOS only. Mobile support is outside the MVP scope.

2. Technology Stack

Component	Technology	Responsibility
Native application	Swift	macOS integration and application lifecycle
UI framework	SwiftUI	User interface
AI backend	Python	LLM integration, planning, and task orchestration
Communication	HTTP + JSON	Communication between Swift and Python
Speech recognition	Local speech-to-text initially	Convert spoken instructions into text
LLM	Cloud-based initially	Understand instructions and determine appropriate actions
UI interaction	macOS Accessibility APIs	Interact with application UI elements
Fallback interaction	Keyboard and mouse simulation	Handle interactions that Accessibility APIs cannot perform
Visual observation	Screenshots and vision models when needed	Understand UI state when other mechanisms are insufficient

SwiftUI is the primary UI framework. AppKit can be used when specific macOS capabilities are not conveniently available through SwiftUI.

3. High-Level Architecture

The application consists of two separate processes.

┌──────────────────────────────────────┐
│          macOS Application           │
│             Swift + SwiftUI          │
│                                      │
│  • User interface                    │
│  • Microphone and activation         │
│  • Speech-to-text integration        │
│  • macOS system interaction          │
│  • Action execution                  │
│  • Result observation and reporting  │
└──────────────────┬───────────────────┘
                   │
                   │ Local HTTP + JSON
                   │
┌──────────────────▼───────────────────┐
│           Python Backend             │
│                                      │
│  • LLM integration                   │
│  • Instruction interpretation        │
│  • Task planning and orchestration   │
│  • Task-state management             │
│  • Policy and authorization checks   │
│  • Failure recovery                  │
└──────────────────────────────────────┘

The Swift application handles native macOS operations, while Python handles AI orchestration.

The two components run as separate processes, so they require an interprocess communication mechanism.

4. Communication Between Swift and Python

Initial choice: HTTP over localhost.

The Python backend will listen on a local-only address such as 127.0.0.1.

Communication will use JSON requests and responses.

Initial API endpoints:

HTTP Method	Endpoint	Purpose
POST	/tasks	Submit a new instruction
GET	/tasks/{task_id}	Retrieve task status and progress
POST	/tasks/{task_id}/cancel	Request task cancellation
GET	/health	Check backend availability

Example request:

{
  "instruction": "Open Safari and search for AI news."
}

Example response:

{
  "task_id": "abc123",
  "status": "running",
  "message": "Executing your instruction"
}

Security requirements:

* Bind the server to localhost rather than exposing it to the network.
* Authenticate requests appropriately.
* Validate all incoming requests.
* Never execute an action solely because it arrived through HTTP.

HTTP is sufficient for the MVP. WebSockets can be considered later if real-time streaming or progress updates justify them.

5. Instruction Processing and Execution

The general execution flow is:

1. Activation: The user activates the assistant.
2. Speech recognition: The spoken instruction is converted into text.
3. Instruction interpretation: The Python backend sends the instruction and relevant context to the LLM.
4. Planning: The LLM proposes structured actions.
5. Validation: The application validates proposed actions against its permissions and safety policies.
6. Execution: Swift performs the approved actions using macOS APIs.
7. Observation: The application collects relevant information about the resulting system state.
8. Verification: The application checks whether the intended outcome was achieved.
9. Recovery: If an action fails, the system reassesses and tries a safe alternative when appropriate.
10. Completion: The user receives the result or an explanation of why the task could not be completed.

The system must not blindly execute an entire multi-step plan without checking intermediate results.

6. Action Execution Strategy

Use a layered approach:

Primary: Accessibility APIs

Use macOS Accessibility APIs to identify and interact with UI elements, including buttons, text fields, and menus.

Fallback: Keyboard and mouse simulation

Use simulated input when Accessibility APIs cannot perform the required interaction.

Additional mechanism: Visual observation

Use screenshots and vision models when the current UI state cannot be determined reliably through Accessibility APIs or other available information.

Whenever practical, verify that important actions produced the expected result.

7. Task Management

The Python backend will manage task orchestration and track task progress.

Initial task states:

* PENDING
* RUNNING
* WAITING_FOR_APPROVAL
* COMPLETED
* FAILED
* CANCELLED

Each task receives a unique identifier.

The application should initially execute one active task at a time. Independent actions can be parallelized later if there is a clear benefit.

Task state should be persisted locally when necessary to support recovery after interruptions. Conversation history and task-state records should remain separate because they serve different purposes.

8. Failure Recovery

The system should distinguish between temporary failures, execution failures, and situations requiring user intervention.

The recovery strategy is:

1. Detect and classify the failure.
2. Retry only when the operation is safe to retry.
3. Reassess the current state if the action fails.
4. Attempt an alternative strategy when appropriate.
5. Ask the user for help if recovery is unsuccessful.

The system must avoid blindly repeating actions that could have irreversible or duplicate effects.

9. Permissions and Security

The application will require appropriate macOS permissions for the capabilities it uses, potentially including:

* Microphone access.
* Accessibility access.
* Automation permissions for controlling other applications.
* Screen Recording permission when screenshot capture requires it.

Permissions are capability-specific; granting one permission does not automatically grant every other permission.

Actions should be classified by risk:

* Low-risk actions can generally run automatically.
* Consequential actions should require confirmation when appropriate.
* Sensitive or unauthorized actions must be blocked.

Security checks must be enforced by the application, not delegated entirely to the LLM.

The application should maintain structured logs of important actions, results, errors, and recovery attempts without unnecessarily recording sensitive user data.

10. Voice Activation

The intended experience supports two activation modes:

* Push-to-talk.
* Wake-word activation.

Implement push-to-talk first because it is simpler to build and test.

Wake-word detection can be added later, preferably using local processing.

Speech recognition should remain replaceable so that different models or providers can be evaluated without redesigning the entire application.

11. AI Execution Strategy

Initial approach:

* Local speech recognition.
* Cloud-based LLM for reasoning and planning.
* Python backend for orchestration.
* Swift for native macOS interaction.

The backend should be designed so that the LLM provider can be changed later. Local LLM support can also be considered in a future version.

The LLM proposes actions; the task manager coordinates execution; the action executor performs the actual operations.

12. Important Architectural Principles

1. Modularity: Keep UI, AI orchestration, task management, and action execution separate.
2. Structured actions: The LLM should produce validated, structured action requests rather than unrestricted commands by default.
3. Least privilege: Request only the system permissions needed for supported capabilities.
4. Independent policy enforcement: The application must enforce security rules independently of the LLM.
5. Observe and verify: Check results instead of assuming every action succeeded.
6. Safe recovery: Retry or change strategies only when appropriate.
7. Replaceable components: Keep speech recognition, LLM providers, and interaction mechanisms replaceable.
8. Observability: Maintain structured logs for debugging and reliability.
9. Incremental development: Build and validate a small working system before expanding its capabilities.

13. Current Decisions and Remaining Work

Decisions made

* Native macOS application.
* Swift + SwiftUI frontend.
* Python AI backend.
* Separate processes communicating through local HTTP.
* JSON request and response format.
* Local speech recognition and cloud LLM initially.
* Structured actions rather than unrestricted LLM execution.
* Accessibility APIs as the primary UI interaction mechanism.
* Keyboard/mouse simulation and visual observation as complementary mechanisms.
* Task-state tracking, verification, and failure recovery.
* Push-to-talk before wake-word activation.
* One active task at a time initially.

Remaining before implementation

1. Finalize the MVP feature scope.
2. Define the exact API contract and structured action schema.
3. Decide how the packaged macOS application will start, supervise, and stop the Python backend.
4. Establish the implementation sequence.
5. Begin development and validate each component incrementally.