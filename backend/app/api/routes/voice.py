"""WebSocket /voice/stream: hands-free listening.

The app streams raw 16 kHz mono 16-bit PCM as binary messages and controls the
stream with JSON text messages:
  {"mode": "wake" | "command" | "idle"}   what to listen for
  {"action": "finish"}                    end the current command now
The backend replies with JSON events:
  {"type": "ready", "wake_available": bool, "wake_phrase": str}
  {"type": "wake"}                         wake word heard and confirmed; recording the command
  {"type": "transcribing"}                 the user stopped talking
  {"type": "transcript", "text": str, "provider": str}
  {"type": "no_speech"}
  {"type": "error", "message": str}
After a transcript or no_speech the stream is idle until the app sets a mode again.
"""

from __future__ import annotations

import asyncio
import json
import logging
import secrets

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, status

from app.speech.base import SpeechError
from app.speech.mock import MockSpeechRecognizer
from app.speech.voice_stream import Event, Mode, VoiceStream, build_voice_stream, matches_phrase, to_wav

router = APIRouter()
log = logging.getLogger(__name__)


def _authorized(ws: WebSocket) -> bool:
    expected: str = ws.app.state.api_token
    header = ws.headers.get("authorization", "")
    token = header.removeprefix("Bearer ").strip()
    return bool(token) and secrets.compare_digest(token.encode(), expected.encode())


@router.websocket("/voice/stream")
async def voice_stream(ws: WebSocket) -> None:
    if not _authorized(ws):
        await ws.close(code=status.WS_1008_POLICY_VIOLATION)
        return
    await ws.accept()

    settings = ws.app.state.settings
    factory = ws.app.state.voice_factory
    try:
        stream: VoiceStream = await asyncio.to_thread(
            factory, settings.wake_word_model, settings.wake_word_threshold
        )
    except Exception as exc:  # noqa: BLE001 - report any model problem to the app
        log.error("voice_unavailable", extra={"error": type(exc).__name__})
        await ws.send_json({"type": "error", "message": "Hands-free listening isn't set up. "
                                                        "Run scripts/dev.sh setup."})
        await ws.close()
        return

    await ws.send_json({"type": "ready", "wake_available": stream.wake_available,
                        "wake_phrase": settings.wake_word_phrase})
    speech = ws.app.state.speech
    verifier = ws.app.state.wake_verifier
    send_lock = asyncio.Lock()
    background: set[asyncio.Task] = set()

    async def send(payload: dict) -> None:
        async with send_lock:
            await ws.send_json(payload)

    async def verify(clip) -> None:
        ok = True
        if not isinstance(verifier, MockSpeechRecognizer):
            try:
                heard = await asyncio.to_thread(verifier.transcribe, to_wav(clip))
                ok = matches_phrase(heard.text, settings.wake_word_phrase)
            except SpeechError:
                ok = False
        log.info("wake_word_candidate", extra={"confirmed": ok})
        await handle(stream.verified(ok))

    async def transcribe(audio) -> None:
        try:
            result = await asyncio.to_thread(speech.transcribe, to_wav(audio))
            log.info("voice_transcript", extra={"provider": result.provider, "chars": len(result.text)})
            await send({"type": "transcript", "text": result.text, "provider": result.provider})
        except SpeechError as exc:
            log.warning("voice_transcribe_failed", extra={"error": str(exc)})
            await send({"type": "error", "message": str(exc)})
        except Exception:  # noqa: BLE001 - never leave the app waiting for a transcript
            log.exception("voice_transcribe_crashed")
            await send({"type": "error", "message": "Speech recognition failed."})

    def spawn(coro) -> None:
        task = asyncio.create_task(coro)
        background.add(task)
        task.add_done_callback(background.discard)

    async def handle(events: list[Event]) -> None:
        for event in events:
            if event.kind == "candidate":
                spawn(verify(event.audio))
            elif event.kind == "wake":
                await send({"type": "wake"})
            elif event.kind == "utterance":
                await send({"type": "transcribing"})
                spawn(transcribe(event.audio))
            elif event.kind == "no_speech":
                await send({"type": "no_speech"})

    try:
        while True:
            message = await ws.receive()
            if message["type"] == "websocket.disconnect":
                break
            if message.get("bytes") is not None:
                await handle(await asyncio.to_thread(stream.feed, message["bytes"]))
            elif message.get("text") is not None:
                try:
                    control = json.loads(message["text"])
                except json.JSONDecodeError:
                    continue
                if control.get("action") == "finish":
                    await handle(stream.finish())
                elif control.get("mode") in {m.value for m in (Mode.IDLE, Mode.WAKE, Mode.COMMAND)}:
                    stream.set_mode(Mode(control["mode"]))
                    log.info("voice_mode", extra={"mode": control["mode"]})
    except WebSocketDisconnect:
        pass
    finally:
        for task in background:
            task.cancel()
