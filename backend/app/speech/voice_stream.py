"""Listening on a live 16 kHz audio stream.

Silero VAD (on-device) notices when the user stops talking, so a command can be
transcribed and sent without a second key press.

`VoiceStream` is the state machine; the voice-activity scorer is injected so it can be
tested without models. Audio is kept in memory only.
"""

from __future__ import annotations

import importlib.util
import io
import logging
import threading
import wave
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Protocol

import numpy as np

from app.speech.base import SAMPLE_RATE

log = logging.getLogger(__name__)

CHUNK = 1280  # 80 ms
CHUNK_SECONDS = CHUNK / SAMPLE_RATE

SPEECH_PROBABILITY = 0.5
END_SILENCE_SECONDS = 0.9    # pause that ends a command
NO_SPEECH_SECONDS = 6.0      # give up if nothing is said after listening starts
MAX_COMMAND_SECONDS = 20.0
MIN_SPEECH_SECONDS = 0.3     # shorter bursts (a cough, a click) aren't a command


class Scorer(Protocol):
    def score(self, chunk: np.ndarray) -> float: ...
    def reset(self) -> None: ...


class Mode(StrEnum):
    IDLE = "idle"
    COMMAND = "command"  # recording a command until the user stops talking


@dataclass(frozen=True)
class Event:
    kind: str  # "utterance" | "no_speech"
    audio: np.ndarray | None = None


class VoiceStream:
    def __init__(self, vad: Scorer) -> None:
        self._vad = vad
        self._lock = threading.Lock()
        self._pending = np.zeros(0, dtype=np.int16)
        self._command: list[np.ndarray] = []
        self._heard_speech = False
        self._speech = 0.0
        self._silence = 0.0
        self._elapsed = 0.0
        self.mode = Mode.IDLE

    def set_mode(self, mode: Mode) -> None:
        with self._lock:
            self._enter(mode)

    def finish(self) -> list[Event]:
        """End the current command now (the shortcut was pressed again)."""
        with self._lock:
            if self.mode != Mode.COMMAND:
                return []
            return [self._end_command()]

    def feed(self, pcm: bytes) -> list[Event]:
        """Add little-endian 16-bit PCM audio and return what happened."""
        events: list[Event] = []
        with self._lock:
            if self.mode == Mode.IDLE:
                return events
            samples = np.frombuffer(pcm[: len(pcm) - len(pcm) % 2], dtype="<i2")
            self._pending = np.concatenate([self._pending, samples])
            while len(self._pending) >= CHUNK and self.mode != Mode.IDLE:
                chunk, self._pending = self._pending[:CHUNK], self._pending[CHUNK:]
                event = self._process(chunk)
                if event:
                    events.append(event)
        return events

    def _process(self, chunk: np.ndarray) -> Event | None:
        """Record the chunk and watch for the end of speech."""
        self._command.append(chunk)
        self._elapsed += CHUNK_SECONDS
        if self._vad.score(chunk) >= SPEECH_PROBABILITY:
            self._heard_speech = True
            self._speech += CHUNK_SECONDS
            self._silence = 0.0
        elif self._heard_speech:
            self._silence += CHUNK_SECONDS

        if self._heard_speech and (self._silence >= END_SILENCE_SECONDS
                                   or self._elapsed >= MAX_COMMAND_SECONDS):
            return self._end_command()
        if not self._heard_speech and self._elapsed >= NO_SPEECH_SECONDS:
            return self._end_command()
        return None

    def _end_command(self) -> Event:
        audio = np.concatenate(self._command) if self._command else np.zeros(0, dtype=np.int16)
        enough = self._speech >= MIN_SPEECH_SECONDS
        event = Event("utterance", audio) if enough else Event("no_speech")
        log.info("voice_command_ended", extra={"seconds": round(self._elapsed, 1),
                                               "speech_seconds": round(self._speech, 1)})
        self._enter(Mode.IDLE)
        return event

    def _enter(self, mode: Mode) -> None:
        self.mode = mode
        self._command = []
        self._heard_speech = False
        self._speech = 0.0
        self._silence = 0.0
        self._elapsed = 0.0
        self._vad.reset()
        if mode == Mode.IDLE:
            self._pending = np.zeros(0, dtype=np.int16)


def to_wav(samples: np.ndarray) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(samples.astype("<i2").tobytes())
    return buffer.getvalue()


# --- Silero VAD (shipped with openWakeWord) ---------------------------------------


def voice_installed() -> bool:
    return importlib.util.find_spec("openwakeword") is not None


class _VADScorer:
    def __init__(self, vad) -> None:
        self._vad = vad

    def score(self, chunk: np.ndarray) -> float:
        return float(self._vad.predict(chunk, frame_size=640))

    def reset(self) -> None:
        self._vad.reset_states()


_download_lock = threading.Lock()


def prepare_models() -> None:
    """Download Silero VAD on first use."""
    import openwakeword
    from openwakeword.utils import download_models

    with _download_lock:
        resources = Path(openwakeword.__file__).parent / "resources" / "models"
        if not (resources / "silero_vad.onnx").exists():
            log.info("voice_models_download")
            download_models([])


def build_voice_stream() -> VoiceStream:
    """Load the VAD model (blocking). Raises if openWakeWord isn't installed."""
    from openwakeword.vad import VAD

    prepare_models()
    return VoiceStream(_VADScorer(VAD()))
