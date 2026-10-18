# Orbito Backend API Contract

Version 0.1.0. The Swift app (`macos/`) and Python backend (`backend/`) talk over
HTTP + JSON on `http://127.0.0.1:8765` (port set by `ORBITO_PORT`).

## Security

- The server binds to `127.0.0.1` only, and rejects any `Host` header other than
  `127.0.0.1` or `localhost`. This prevents DNS-rebinding attacks.
- Every endpoint except `GET /health` requires `Authorization: Bearer <token>`.
- The token comes from `ORBITO_API_TOKEN`. If that is unset, it is read from
  `~/Library/Application Support/Orbito/api-token`, which either side creates
  with mode `0600` if it is missing. The app also passes the token to a backend it
  starts itself through `ORBITO_API_TOKEN`.
- The backend never returns or logs AWS credentials.

## Errors

Every error response has this shape:

```json
{ "error": { "code": "task_active", "message": "Another task is still running. Cancel it first." } }
```

| HTTP | code | When |
|------|------|------|
| 400 | — | Disallowed `Host` header |
| 401 | `unauthorized` | Missing or wrong token |
| 404 | `not_found` | Unknown task |
| 409 | `task_active` / `conflict` | A task is already active, or the request doesn't fit the task's current state |
| 413 / 415 | `http_error` | Audio too large, or wrong content type |
| 422 | `invalid_request` / `invalid_audio` | Validation failed |
| 503 | `speech_unavailable` | The speech model couldn't load or run |

`message` is always safe to show to the user.

## Task states

`pending → running → (waiting_for_approval ↔ running)* → completed | failed | cancelled`

| status | Meaning |
|--------|---------|
| `pending` | Created, not yet planned |
| `running` | Planning, or an action is ready to run or running |
| `waiting_for_approval` | The current action needs the user's approval |
| `completed` | Every action succeeded |
| `failed` | Planning failed, or an action failed and couldn't be retried safely |
| `cancelled` | Cancelled by the user, or the user declined an approval |

Only one task can be active (non-terminal) at a time.

Action `status` values:

| status | Meaning |
|--------|---------|
| `queued` | Not reached yet |
| `awaiting_approval` | Waiting for the user's approval |
| `ready` | The app should execute it now |
| `succeeded` | Finished successfully |
| `failed` | Failed and won't be retried |
| `skipped` | Not run, because the task stopped first |

## Endpoints

### `GET /health` (no auth)

```json
{ "status": "ok", "version": "0.1.0", "llm_provider": "bedrock", "speech_provider": "whistle" }
```

`llm_provider` is `"groq"`, `"bedrock"`, or `"mock"`. `speech_provider` is
`"whistle"` or `"mock"`. A value of `"mock"` means a labelled mock is in use.

### `POST /tasks` → 201

Request: `{ "instruction": "Open Safari and search for AI news." }`. Unknown fields
are rejected. The instruction is trimmed, control characters are removed, and it
must be 1–1000 characters long.

```json
{ "task_id": "6f9fb9d3c22e48b1be63951278274a1c", "status": "pending", "message": "Task created" }
```

### `GET /tasks/{task_id}` → 200

```json
{
  "task_id": "6f9f…",
  "instruction": "Open Safari and search for AI news.",
  "status": "running",
  "message": "Step 1 of 2: Open Safari",
  "result": null,
  "error": null,
  "planner": "mock",
  "actions": [ActionView, …],
  "next_action": ActionView | null,
  "created_at": "2026-10-18T11:36:26Z",
  "updated_at": "2026-10-18T11:36:26Z"
}
```

`ActionView`:

```json
{
  "action_id": "f6d930928388",
  "type": "open_application",
  "parameters": { "application_name": "Safari" },
  "description": "Open Safari",
  "requires_approval": false,
  "status": "ready",
  "attempt": 1,
  "observation": null,
  "error": null
}
```

`next_action` is non-null only when the app should execute that action now.
The app executes each `(action_id, attempt)` pair at most once.

### `POST /tasks/{task_id}/cancel` → 200

Returns the updated task, as in `GET`. Cancelling a finished task returns it unchanged.

### `POST /tasks/{task_id}/approval` → 200

Request: `{ "approved": true }`. Returns 409 unless the task is
`waiting_for_approval`. If `approved` is `false`, the task is cancelled.

### `POST /tasks/{task_id}/actions/{action_id}/result` → 200

Sent by the app after it executes `next_action`:

```json
{ "attempt": 1, "success": false, "observation": "Safari is frontmost", "error": "Timed out", "retryable": true }
```

Returns 409 if the action is not the current `next_action` with the same `attempt`.
A failure is retried (`attempt + 1`) only when the action is retry-safe and
`retryable` is true, up to 2 attempts. Otherwise the task fails.

### `POST /speech/transcribe` → 200

The body is raw `audio/wav`: 16 kHz, mono, 16-bit PCM, at most 10 MB.

```json
{ "text": "Open Safari and search for AI news", "language": "en", "provider": "whistle", "duration_seconds": 2.49 }
```

## Action allowlist

The LLM can propose only these actions. The backend validates them strictly, and
unknown parameters are rejected. The macOS app checks them again before executing.

| type | parameters | risk | retry-safe |
|------|-----------|------|-----------|
| `open_application` | `application_name` | low | yes |
| `open_url` | `url` (http/https only), `application_name?` | low | no |
| `search_web` | `query` (≤300), `application_name?` | low | no |
| `type_text` | `text` (≤500) | **needs approval** | no |
| `press_key` | `key` (return, tab, escape, space, delete, arrows, a–z, 0–9), `modifiers?` (command/shift/option/control) | **needs approval** | no |

Shortcuts that quit apps, log out, lock the screen, force-quit or delete files
(for example ⌘Q, ⌥⌘⎋, ⌘⌫) are always blocked. A plan can have at most 8 actions.
