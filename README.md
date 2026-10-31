<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/orbito-logo-dark.png">
    <img src="docs/assets/orbito-logo-light.png" alt="Orbito" width="360">
  </picture>
</p>

<p align="center"><b>A voice assistant for macOS</b></p>

Hold the mic button and say what you want, for example "Open Safari and search
for AI news". Orbito turns your speech into text on your Mac, lets you review or
edit it, plans safe actions with an LLM, and runs them on your Mac. It checks the
result of each step as it goes.

```
macos/    SwiftUI app: UI, microphone, backend supervision, macOS action execution
backend/  Python FastAPI service: speech-to-text, LLM planning, policy, task state
shared/   api-contract.md, the HTTP/JSON contract between the two
scripts/  dev.sh (setup / run / test), package.sh (build Orbito.app)
```

## Requirements

- macOS 14 or later, Apple Silicon (the Whistle engine ships `macos-arm64` binaries)
- Swift 5.10 or later. The Xcode Command Line Tools are enough; full Xcode isn't needed.
- Python 3.11 or later
- Optional: a Groq API key, or AWS credentials with access to a Bedrock model

## Quick start

```bash
scripts/dev.sh setup   # creates backend/.venv and installs FastAPI, boto3 and cactus-needle
scripts/dev.sh app     # builds and launches the app; the app starts the backend itself
```

The first launch downloads the Whistle speech model (about 17 MB) from Hugging Face.
After that, transcription runs offline.

Other commands:

```bash
scripts/dev.sh backend   # run only the backend in the foreground
scripts/dev.sh test      # backend pytest + Swift tests
scripts/package.sh       # build build/Orbito.app (see "Packaging")
```

## Configuring the planner (Groq or AWS Bedrock)

If no LLM is configured, the backend uses a **mock planner**. The header shows
a "Mock planner" badge while it's active. The mock planner is rule-based and only
understands simple commands such as "open Notes", "go to apple.com" or
"open Chrome and search for weather".

Put all keys in `backend/.env`, which git ignores. Never put them in `.env.example`,
because that file is committed. With `ORBITO_LLM_PROVIDER=auto` (the default),
Orbito uses Bedrock if it's fully configured, then Groq, then the mock planner.

### Groq

Add these lines to `backend/.env`:

```
GROQ_API_KEY=<your key from console.groq.com>
ORBITO_GROQ_MODEL_ID=openai/gpt-oss-120b
```

The model must support tool calling. Restart the backend (Settings → Restart
backend), and `/health` should then report `"llm_provider": "groq"`.

### AWS Bedrock

To use Bedrock:

1. Set up AWS credentials in any standard way, such as `aws configure`, `aws sso login`
   or `AWS_PROFILE`. Alternatively, put a Bedrock API key in `backend/.env` as
   `AWS_BEARER_TOKEN_BEDROCK=…`; some AWS Organizations block these keys with a
   service control policy. Orbito never logs your credentials and doesn't pass them
   to the Swift app.
2. Copy `backend/.env.example` to `backend/.env` and set:
   ```
   AWS_REGION=us-east-1
   ORBITO_BEDROCK_MODEL_ID=<a model ID enabled in your account>
   ```
   The model must support the Bedrock **Converse API with tool use**. There's
   deliberately no default model.
3. Restart the backend (Settings → Restart backend). `/health` should then report
   `"llm_provider": "bedrock"`.

Bedrock failures are turned into readable task errors: authentication or model
access, throttling, timeouts, a model ID that doesn't exist, and malformed replies.
Orbito never switches to the mock planner on its own once Bedrock is configured.
To require Bedrock, set `ORBITO_LLM_PROVIDER=bedrock`. Startup then fails if
Bedrock isn't available.

## Speech recognition (Groq Whisper, with Whistle offline)

When `GROQ_API_KEY` is set, commands are transcribed by **Whisper large-v3-turbo on
Groq** (about 0.3 s, and far more accurate on accents and app names). The names of
your installed apps are sent with each request as a vocabulary hint, so "Chrome"
isn't heard as "Crown". The audio goes to Groq and is not stored by Orbito.

If Groq can't be reached, Orbito falls back to **Cactus Whistle** on your Mac
(`cactus-needle`, about 17 MB, telemetry off). Whistle also does the quick
wake-word double-check, so those clips never leave your Mac. With neither available,
a **mock transcriber** returns a fixed sentence and the app labels it.

Set `ORBITO_SPEECH_PROVIDER=whistle` to keep all audio on your Mac, and
`ORBITO_SPEECH_LANGUAGE` if you speak to Orbito in a language other than English.

## The notch, the shortcut and the wake word

Tap **⌃ Control + ⌥ Option** together in any app and start talking (or hold them
while you speak and let go to send). Orbito grows down out of the MacBook's camera notch with a live
waveform. When you stop talking, it transcribes your command, shows it for about a
second (click ✕ to cancel) and sends it. Tap the keys again to send straight away.
Steps that need approval show **Allow** and **Deny** in the notch. Just say "yes" or
"no" ("go ahead", "allow", "deny", "cancel" also work), or click.

After the first tap, Orbito also listens for **"Hey Jarvis"**, so the next command
needs no keys at all. This is a stand-in until the custom "Hey Orbito" model is
trained. Each detection is double-checked by Whistle, because the fast wake-word
model also reacts to similar phrases. Turn it off from the main window or in Settings.

- Wake word: openWakeWord. End of speech: Silero VAD. Both run on your Mac, and
  their models (about 8 MB) download on first use. Audio is never saved.
- Settings → Voice shortcut: choose ⌃⌥, fn⌃ or ⌥⌘; turn the wake word, automatic
  sending and **Launch Orbito at login** (packaged app only) on or off.
- To use your own wake word, set `ORBITO_WAKE_WORD_MODEL=/path/to/model.onnx` and
  `ORBITO_WAKE_WORD_PHRASE=hey orbito` in `backend/.env`.
- The notch panel never takes keyboard focus, and closing the main window keeps
  Orbito running in the notch. Quit with ⌘Q.

### Agent mode

Tap ⌃⌥ and turn on **Agent mode** with the switch in the notch. Now just talk: "open
Calculator" → "type 2 plus 2" → "now close it" → "scroll down". There's no wake word
and no keys between requests.

- Orbito remembers the last few requests, so "it" and "that app" work.
- Speech that isn't a request (a phone call, background talk) is ignored by the planner.
- While a task runs, say **"stop"** to cancel it.
- Short typing (up to 100 characters) runs without an Allow click; key presses and
  longer text still ask.
- Tap ⌃⌥ or flip the switch to turn it off. It also turns off after 5 quiet minutes.

## Supported actions

| Action | Example | Approval |
|---|---|---|
| Open an app | "Open Notes" | automatic |
| Open a link (http/https only) | "Go to apple.com" | automatic |
| Web search | "Search for AI news" | automatic |
| Close an app (normal quit) | "Close Calculator" | automatic |
| Scroll the front window | "Scroll down" | automatic (needs Accessibility) |
| Type text | "Type hello world" | **asks first** (short text is automatic in agent mode) |
| Press a key or shortcut | "Press command t" | **asks first** |

The backend and the app each enforce this list separately. Shortcuts that quit,
log out, lock or delete things are always blocked. The LLM can't run shell commands.

## macOS permissions

Orbito asks for each permission only when it first needs it.

- **Microphone**: asked the first time you hold the mic button.
- **Accessibility**: needed only for typing and key presses (System Settings →
  Privacy & Security → Accessibility). Opening apps and links doesn't need it.

When you run the app with `swift run` or `scripts/dev.sh app`, macOS gives these
permissions to the terminal or editor that launched it. Use `scripts/package.sh`
to get permissions that belong to Orbito itself.

## Security model

- The backend binds to `127.0.0.1` only and rejects any `Host` header other than
  loopback, which protects against DNS rebinding.
- Every endpoint except `/health` needs a bearer token. The token is stored in
  `~/Library/Application Support/Orbito/api-token` with mode 0600, and the app
  passes it to the backend it launches.
- Plans are validated against a strict schema. Unknown action types or parameters
  are rejected.
- Logs record event names, IDs and action types. They never include your
  instructions, transcripts or typed text.
- Task state is saved to `~/Library/Application Support/Orbito/tasks.json` (0600).
  If the backend restarts, any task that was in progress is marked as failed rather
  than resumed, so no step can run twice.

## Development notes

- Backend logs: `~/Library/Application Support/Orbito/backend.log`, or Settings → Show log.
- App logs: `log stream --predicate 'subsystem == "dev.orbito.assistant"'`
- Settings → Animation preview shows any of the bot's seven states without a backend.
- To use a backend you started yourself, run `scripts/dev.sh backend` before the app.
  The app connects to an already-running backend instead of starting a second one.

## Status

| Stage | State |
|---|---|
| 1. Native UI | Done |
| 2. Python backend | Done |
| 3. Swift ↔ Python | Done |
| 4. LLM planner | **Groq works against the live API** (`openai/gpt-oss-120b`, plans in about 0.5–1.2 s). Bedrock is implemented and unit-tested, but the available AWS account blocks Bedrock API keys with a service control policy |
| 5. Whistle | Done; real transcription verified, but **not yet tested with a live microphone** |
| 6. macOS actions | Opening apps verified end to end; typing and key presses are implemented but **not yet tested** (they need Accessibility permission) |
| 7. Reliability | Structured logs, persistence and restart recovery done; finer recovery strategies still to do |
| 8. Packaging | `package.sh` builds a signed `.app` that includes the backend source, but it still needs a Python environment on the Mac |

Remaining work:

- Embed a relocatable Python runtime (for example python-build-standalone) for a self-contained `.app`.
- Notarization.
- Streaming transcription: Whistle supports streaming, but the app doesn't use it yet.
- A custom "Hey Orbito" wake-word model ("Hey Jarvis" is used for now).
- Vision-based observation.

## Active project

Orbito is under active development, so features, the API and the UI change often.
Up next: training the "Hey Orbito" wake-word model and more accurate on-device
speech recognition.
