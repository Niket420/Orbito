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

14. Design Decisions (why this, why not that)

LLM provider

* Groq (openai/gpt-oss-120b) is the active planner. AWS Bedrock is implemented, but the available AWS account blocks Bedrock API keys with a service control policy.
* Plans use forced tool calling with a separate JSON schema for each action type. A generic schema let the model return empty parameters (for example, "open Chrome" without application_name).
* A rejected plan is retried once, and the validation error is sent back to the model so it can correct the plan.

Speech-to-text

* Whistle (about 17 MB, on-device) was too inaccurate in real use: accents and app names ("Chrome" heard as "Crown"). A tiny model can't be fixed by code around it.
* Commands now go to Whisper large-v3-turbo on Groq: the best accuracy, about 0.3 s, and no RAM cost. The command text already goes to Groq for planning, so sending the audio is a small extra privacy step for a big accuracy gain.
* Installed app names are sent as a vocabulary hint with each request.
* Whistle stays as the offline fallback and does the wake-word double-check, so those frequent clips never leave the Mac.
* Not chosen: on-device models around 1 GB (too heavy for an always-running app); Apple's on-device recognizer (good, but weaker on accents; its much better SpeechAnalyzer needs macOS 26).

Notch UI

* The panel is non-activating, so it never takes keyboard focus from the user's app.
* All content is drawn below the camera notch, never beside it. The notch is solid hardware and hid content placed next to it on the M2 Air.

Keyboard shortcut

* The shortcut is a tap of two modifier keys: ⌃⌥ (the default), fn⌃ or ⌥⌘. A tap starts listening, and the command is sent when the user stops talking, so nothing has to be held down.
* Modifier-only shortcuts can't be registered as macOS hot keys. Orbito samples the global modifier state about 30 times a second instead, which needs no permission. A tap counts only when exactly those two keys are pressed and released within 0.8 s with no other key in between, so shortcuts like ⌃⌥⌘T or ⌃→ don't trigger it.
* Carbon hot keys (the first version) were dropped. Since macOS 15, ⌥-only shortcuts such as ⌥ Space register without an error but never fire, and a key recorder can't capture modifier-only combinations.
* "Launch at login" is offered because an app cannot listen for a shortcut while it isn't running.

Agent mode (continuous conversation)

* A switch in the notch. When on, the voice-activity detector splits speech into requests and each one is sent, with no wake word.
* Memory: tasks carry a session id, and the planner sees the last 5 turns of the session, so "now close it" resolves to the app opened before.
* Always listening means hearing things that aren't requests. The planner can answer "not a command", and Orbito drops filler words and Whisper's silence hallucinations ("thank you").
* While a task runs, only "stop" is acted on.
* Short typing is approved automatically in agent mode, because clicking Allow breaks the flow. Key presses and long text still ask, and the action allowlist still applies.
* It turns off after 5 quiet minutes, and the notch shows when it's on.
* close_application quits normally (apps can still ask to save); force quit and ⌘Q stay blocked. scroll moves the pointer into the front window first, because macOS sends scroll events to whatever is under the pointer.
* Next: a plan → act → observe loop, so the planner sees the screen after each step instead of planning blind.

Wake word: built with "Hey Jarvis" as a stand-in until the custom "Hey Orbito" model is trained

* Set ORBITO_WAKE_WORD_MODEL to the trained .onnx path and ORBITO_WAKE_WORD_PHRASE to "hey orbito" to switch.
* Hands-free audio is streamed over a local WebSocket (/voice/stream), so the backend does wake word, end-of-speech and transcription in one place.
* Tested on synthetic speech: "Hey Charles" scored 0.99 on the Hey Jarvis model, and the Whistle double-check rejected it. This confirms that step is needed.

User flow:

1. Open Orbito and press the shortcut once. Orbito is now on and waiting.
2. Say "Hey Orbito", or click the mic, to start listening.
3. Say the command. It is sent automatically when the user stops talking.
4. Orbito goes back to waiting. Pressing the shortcut again turns it off.

How "Hey Siri" works, and why Orbito copies its design:

* A tiny always-on model on a low-power chip spots the phrase.
* A bigger model double-checks it.
* A voice profile confirms the speaker is the owner.
* Apple does not let other apps use Siri's wake-word detector. The only route is through Siri itself ("Hey Siri, Orbito"), which can be added later through App Intents as an extra way in.

Chosen pipeline:

Step	Component	Why
1. Spot the phrase	openWakeWord, with a custom "Hey Orbito" model (about 3 MB)	Free, offline, low CPU, can run all the time
2. Confirm	Whistle (already in the app)	Turns the clip into text and checks for "hey orbito", which cuts false triggers. Runs only when step 1 fires.
3. End of command	Silero VAD (about 2 MB)	Detects when the user stops talking so the command can be sent automatically

* Voice matching (speaker verification) is dropped. It adds computation and setup, and for a personal Mac app, others being able to wake Orbito is acceptable.
* Whistle does not run continuously. While the user speaks the command, only Silero runs. When Silero detects silence, recording stops, Whistle transcribes the clip once, and the text goes to the LLM.

Why openWakeWord over the alternatives:

* Picovoice Porcupine: most accurate and needs no training, but needs an account key and a paid license for commercial use.
* sherpa-onnx keyword spotting: free and needs no training (the phrase is given as text), but is usually less accurate. Good for a quick prototype.
* Vosk restricted to one phrase: works, but is bigger (about 40 MB) and uses more CPU.
* Transcribing everything and matching the text: heaviest on battery and CPU, and "Orbito" is often misheard.
* Few-shot voice fingerprint: weak with other voices and with background noise.

Training openWakeWord:

* openWakeWord has no ready-made "Hey Orbito" model, so the team trains one once with openWakeWord's Colab notebook (about an hour).
* The notebook generates thousands of synthetic voice clips, so no recordings are needed. Because it learns the words from many voices, it works for every user without per-user training.
* For prototyping, the ready-made "Hey Jarvis" model can be used. The ready-made models are licensed for non-commercial use only.

Why Silero VAD:

* A simple volume threshold treats fans, music and typing as speech, so the recording never ends.
* WebRTC VAD makes more mistakes when there is background noise.
* Silero is small, fast and accurate even with noise. It is pre-trained, MIT-licensed and can be used directly.

Audio privacy:

* Audio is kept in memory and streamed only to the local backend on the same Mac.
* Command audio is then sent to Groq for transcription (see section 15). Wake-word checks stay on the Mac. Set ORBITO_SPEECH_PROVIDER=whistle to keep all audio local.
* Whistle reads a temporary file that is deleted automatically straight after transcription. Only the text is kept.
* While Orbito waits for the wake word, audio is checked in short pieces and discarded.

15. Speech-to-Text: from Cactus Whistle to Groq Whisper

Step 1: started with Cactus Whistle (on-device)

* Chosen first because it is tiny (about 17 MB), free, private (audio never leaves the Mac) and fast.
* Verified on synthetic test clips, and it worked.

Step 2: real use showed the problem

* With a real voice it misheard commands, especially with accents and app names ("Chrome" heard as "Crown").
* Cause: Whistle is a very small model. Code around it can't make it more accurate.

Step 3: options considered

Option	Why not (or why)
Larger on-device models (WhisperKit, Parakeet)	Accurate, but around 0.5–1 GB of RAM, which is too heavy for an always-running assistant
Apple on-device recognizer	Zero size and private, but weaker on accents; the much better SpeechAnalyzer needs macOS 26
Cloud speech API	Best accuracy with no RAM cost, but the audio leaves the Mac

* Decision: use a cloud API. The command text already goes to the cloud LLM for planning, so sending the audio is a small extra privacy step for a big accuracy gain.

Step 4: why Groq

* The Groq API key was already in use for the planner, so there was no new account or setup.
* Whisper large-v3-turbo on Groq is accurate and very fast. Tested: an Indian-English clip was transcribed perfectly in 0.34 s.
* It is among the cheapest cloud options.
* Installed app names are sent as a vocabulary hint, which fixes app-name errors.

Step 5: what Cactus Whistle still does

* It is the offline fallback when Groq can't be reached.
* It double-checks the wake word, which happens often, so those clips stay on the Mac.

Known limits of Groq and the next step

* Groq only transcribes whole clips (no live streaming), so Orbito waits for the user to stop talking before uploading.
* Whisper can invent words during silence ("thank you"). Agent mode filters these.
* For a more instant agent mode, the next option is a streaming service: Deepgram Nova-3 or AssemblyAI Universal-Streaming. They return text while the user speaks and detect the end of a sentence themselves, but they cost more and need a new account. Speech is a separate, replaceable module, so this is an easy swap later.