"""Speech-to-text with Whisper large-v3-turbo on Groq (cloud).

Much more accurate than the on-device Whistle model on accents and app names.
The audio is sent to api.groq.com and is not stored by Orbito. The names of the
installed apps are passed as a vocabulary hint, so "Chrome" isn't heard as "Crown".
If Groq can't be reached, `FallbackRecognizer` uses Whistle on the Mac instead.
"""

from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path

import httpx

from app.speech.base import SpeechError, SpeechRecognizer, Transcription, check_wav

log = logging.getLogger(__name__)

BASE_URL = "https://api.groq.com/openai/v1"
_APP_DIRS = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
             str(Path.home() / "Applications")]
_PROMPT_LIMIT = 600  # Whisper reads only the last ~224 tokens of a prompt


@lru_cache(maxsize=1)
def installed_app_names() -> tuple[str, ...]:
    names = set()
    for directory in _APP_DIRS:
        try:
            names.update(p.stem for p in Path(directory).iterdir() if p.suffix == ".app")
        except OSError:
            continue
    return tuple(sorted(names, key=len))  # short names first, so more fit in the hint


def vocabulary_hint() -> str:
    hint = "Commands for a Mac voice assistant, e.g. open Google Chrome, close Calculator. Apps: "
    for name in installed_app_names():
        if len(hint) + len(name) + 2 > _PROMPT_LIMIT:
            break
        hint += name + ", "
    return hint.rstrip(", ") + "."


class GroqWhisperRecognizer:
    name = "groq-whisper"

    def __init__(self, api_key: str, model_id: str, language: str | None = "en",
                 timeout_seconds: float = 20, client: httpx.Client | None = None) -> None:
        self._model_id = model_id
        self._language = language
        self._client = client or httpx.Client(
            base_url=BASE_URL,
            timeout=httpx.Timeout(timeout_seconds, connect=5),
            headers={"Authorization": f"Bearer {api_key}"},
        )

    def transcribe(self, wav_bytes: bytes) -> Transcription:
        check_wav(wav_bytes)
        data = {"model": self._model_id, "response_format": "json", "temperature": "0",
                "prompt": vocabulary_hint()}
        if self._language:
            data["language"] = self._language
        try:
            response = self._client.post("/audio/transcriptions", data=data,
                                         files={"file": ("speech.wav", wav_bytes, "audio/wav")})
        except httpx.HTTPError as exc:
            log.warning("groq_whisper_unreachable", extra={"error": type(exc).__name__})
            raise SpeechError("Couldn't reach Groq for speech recognition.") from exc
        if response.status_code != 200:
            log.warning("groq_whisper_failed", extra={"status": response.status_code})
            if response.status_code == 401:
                raise SpeechError("Groq rejected the API key (GROQ_API_KEY).")
            if response.status_code == 429:
                raise SpeechError("Groq's speech rate limit was reached. Try again in a moment.")
            raise SpeechError(f"Groq speech recognition failed (HTTP {response.status_code}).")
        try:
            text = str(response.json().get("text", "")).strip()
        except ValueError as exc:
            raise SpeechError("Groq returned an unreadable transcription.") from exc
        return Transcription(text=text, language=self._language, provider=self.name)


class FallbackRecognizer:
    """Uses `primary`, and `fallback` whenever the primary fails (e.g. offline)."""

    def __init__(self, primary: SpeechRecognizer, fallback: SpeechRecognizer) -> None:
        self.primary = primary
        self.fallback = fallback
        self.name = primary.name

    def transcribe(self, wav_bytes: bytes) -> Transcription:
        try:
            return self.primary.transcribe(wav_bytes)
        except SpeechError:
            log.warning("speech_fallback", extra={"to": self.fallback.name})
            return self.fallback.transcribe(wav_bytes)
