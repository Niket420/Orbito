"""Hands-free listening on a live 16 kHz audio stream.

Two jobs, both on-device:
- wake word: openWakeWord spots the phrase; Whistle then double-checks it, because
  the fast model alone also fires on similar phrases ("hey Charles" for "hey Jarvis").
- end of speech: Silero VAD notices when the user stops talking, so the command can
  be transcribed and sent without a button.

`VoiceStream` is the state machine; the scorers are injected so it can be tested
without models. Audio is kept in memory only.
"""

from __future__ import annotations

import difflib
import importlib.util
import io
import logging
import re
import threading
import wave
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Protocol

import numpy as np

from app.speech.base import SAMPLE_RATE

log = logging.getLogger(__name__)

CHUNK = 1280  # 80 ms, the frame size openWakeWord expects
CHUNK_SECONDS = CHUNK / SAMPLE_RATE

SPEECH_PROBABILITY = 0.5
END_SILENCE_SECONDS = 0.9    # pause that ends a command
NO_SPEECH_SECONDS = 6.0      # give up if nothing is said after listening starts
MAX_COMMAND_SECONDS = 20.0
WAKE_CLIP_SECONDS = 2.0      # audio checked by Whistle after a detection

_FILLER_WORDS = {"hey", "hi", "ok", "okay"}


class Scorer(Protocol):
    def score(self, chunk: np.ndarray) -> float: ...
    def reset(self) -> None: ...


class Mode(StrEnum):
    IDLE = "idle"
    WAKE = "wake"            # waiting for the wake word
    VERIFYING = "verifying"  # wake word spotted, Whistle is double-checking it
    COMMAND = "command"      # recording a command until the user stops talking


@dataclass(frozen=True)
class Event:
    kind: str  # "candidate" | "wake" | "utterance" | "no_speech"
    audio: np.ndarray | None = None


class VoiceStream:
    def __init__(self, wake: Scorer | None, vad: Scorer, threshold: float = 0.5) -> None:
        self._wake = wake
        self._vad = vad
        self._threshold = threshold
        self._lock = threading.Lock()
        self._pending = np.zeros(0, dtype=np.int16)
        self._recent = np.zeros(0, dtype=np.int16)
        self._command: list[np.ndarray] = []
        self._heard_speech = False
        self._silence = 0.0
        self._elapsed = 0.0
        self.mode = Mode.IDLE

    @property
    def wake_available(self) -> bool:
        return self._wake is not None

    def set_mode(self, mode: Mode) -> None:
        with self._lock:
            if mode == Mode.WAKE and self._wake is None:
                mode = Mode.IDLE
            self._enter(mode)

    def finish(self) -> list[Event]:
        """End the current command now (the shortcut was pressed again)."""
        with self._lock:
            if self.mode != Mode.COMMAND:
                return []
            return [self._end_command()]

    def verified(self, ok: bool) -> list[Event]:
        """Result of Whistle's double-check of a wake-word candidate."""
        with self._lock:
            if self.mode != Mode.VERIFYING:
                return []
            if ok:
                self.mode = Mode.COMMAND  # keeps the audio recorded since the detection
                return [Event("wake")]
            self._enter(Mode.WAKE)
            return []

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
        keep = int(WAKE_CLIP_SECONDS * SAMPLE_RATE)
        self._recent = np.concatenate([self._recent, chunk])[-keep:]

        if self.mode == Mode.WAKE:
            assert self._wake is not None
            if self._wake.score(chunk) >= self._threshold:
                clip = self._recent.copy()
                self._enter(Mode.VERIFYING)
                return Event("candidate", clip)
            return None

        # VERIFYING or COMMAND: record and watch for the end of speech.
        self._command.append(chunk)
        self._elapsed += CHUNK_SECONDS
        if self._vad.score(chunk) >= SPEECH_PROBABILITY:
            self._heard_speech = True
            self._silence = 0.0
        elif self._heard_speech:
            self._silence += CHUNK_SECONDS

        if self.mode != Mode.COMMAND:
            return None
        if self._heard_speech and (self._silence >= END_SILENCE_SECONDS
                                   or self._elapsed >= MAX_COMMAND_SECONDS):
            return self._end_command()
        if not self._heard_speech and self._elapsed >= NO_SPEECH_SECONDS:
            return self._end_command()
        return None

    def _end_command(self) -> Event:
        audio = np.concatenate(self._command) if self._command else np.zeros(0, dtype=np.int16)
        event = Event("utterance", audio) if self._heard_speech else Event("no_speech")
        self._enter(Mode.IDLE)
        return event

    def _enter(self, mode: Mode) -> None:
        self.mode = mode
        self._command = []
        self._heard_speech = False
        self._silence = 0.0
        self._elapsed = 0.0
        self._vad.reset()
        if mode in (Mode.WAKE, Mode.IDLE):
            self._pending = np.zeros(0, dtype=np.int16)
            if self._wake is not None:
                self._wake.reset()


def matches_phrase(text: str, phrase: str) -> bool:
    """True if `text` contains the distinctive words of `phrase`, allowing small
    mishearings ("hey orbit oh" still matches "hey orbito")."""
    heard = re.findall(r"[a-z]+", text.lower())
    wanted = [w for w in re.findall(r"[a-z]+", phrase.lower()) if w not in _FILLER_WORDS]
    if not wanted:
        return True
    candidates = heard + [a + b for a, b in zip(heard, heard[1:])]

    def close(word: str) -> bool:
        return any(difflib.SequenceMatcher(None, word, c).ratio() >= 0.75 for c in candidates)

    return all(close(w) for w in wanted)


def to_wav(samples: np.ndarray) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(samples.astype("<i2").tobytes())
    return buffer.getvalue()


# --- openWakeWord-backed scorers ---------------------------------------------------


def voice_installed() -> bool:
    return importlib.util.find_spec("openwakeword") is not None


class _WakeScorer:
    def __init__(self, model) -> None:
        self._model = model

    def score(self, chunk: np.ndarray) -> float:
        return float(max(self._model.predict(chunk).values()))

    def reset(self) -> None:
        self._model.reset()


class _VADScorer:
    def __init__(self, vad) -> None:
        self._vad = vad

    def score(self, chunk: np.ndarray) -> float:
        return float(self._vad.predict(chunk, frame_size=640))

    def reset(self) -> None:
        self._vad.reset_states()


_download_lock = threading.Lock()


def prepare_models(wake_model: str) -> None:
    """Download openWakeWord's shared models, Silero VAD and a built-in wake word on
    first use. Custom .onnx wake words are used from their path as-is."""
    import openwakeword
    from openwakeword.utils import download_models

    with _download_lock:
        resources = Path(openwakeword.__file__).parent / "resources" / "models"
        builtin = [] if wake_model.endswith(".onnx") else [wake_model]
        have_wake = not builtin or any(resources.glob(f"{wake_model}*.onnx"))
        if not (resources / "silero_vad.onnx").exists() or not have_wake:
            log.info("voice_models_download")
            download_models(builtin)


def build_voice_stream(wake_model: str, threshold: float) -> VoiceStream:
    """Load the models (blocking). Raises if openWakeWord isn't installed."""
    from openwakeword.model import Model
    from openwakeword.vad import VAD

    prepare_models(wake_model)
    wake = _WakeScorer(Model(wakeword_models=[wake_model], inference_framework="onnx"))
    return VoiceStream(wake, _VADScorer(VAD()), threshold)
