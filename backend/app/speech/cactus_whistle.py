"""Cactus Whistle speech-to-text (https://huggingface.co/Cactus-Compute/whistle).

Runs fully on-device through the `cactus-needle` package. Its documented API
is `needle.Whistle().transcribe(audio)`, where audio is a WAV path or 16 kHz
mono float samples; it returns {"text", "language", ...}. One model is loaded
per process and it is not thread-safe, so calls are serialized with a lock.
The weights are downloaded from Hugging Face on first use and cached.
"""

from __future__ import annotations

import importlib.util
import logging
import os
import tempfile
import threading
from typing import Any

from app.speech.base import SpeechError, Transcription, check_wav

log = logging.getLogger(__name__)


def whistle_installed() -> bool:
    return importlib.util.find_spec("needle") is not None


class WhistleRecognizer:
    name = "whistle"

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._model: Any | None = None

    def load(self) -> None:
        """Load (and on first run download) the model. Safe to call repeatedly."""
        with self._lock:
            self._load_locked()

    def _load_locked(self) -> None:
        if self._model is not None:
            return
        # Opt out of the package's anonymous usage counters.
        os.environ.setdefault("NEEDLE_TELEMETRY", "0")
        try:
            import needle

            self._model = needle.Whistle()
        except Exception as exc:  # noqa: BLE001 - surface any load failure cleanly
            log.error("whistle_load_failed", extra={"error": type(exc).__name__})
            raise SpeechError(
                "The Whistle speech model couldn't be loaded. "
                "It needs an internet connection the first time to download."
            ) from exc
        log.info("whistle_loaded")

    def transcribe(self, wav_bytes: bytes) -> Transcription:
        check_wav(wav_bytes)
        with self._lock:
            self._load_locked()
            with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
                tmp.write(wav_bytes)
                tmp.flush()
                try:
                    result = self._model.transcribe(tmp.name)
                except Exception as exc:  # noqa: BLE001
                    log.error("whistle_transcribe_failed", extra={"error": type(exc).__name__})
                    raise SpeechError("Speech recognition failed.") from exc
        return Transcription(
            text=str(result.get("text", "")).strip(),
            language=result.get("language"),
            provider=self.name,
        )
