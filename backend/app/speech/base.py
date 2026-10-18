"""Speech-recognition interface."""

from __future__ import annotations

import io
import wave
from dataclasses import dataclass
from typing import Protocol

SAMPLE_RATE = 16_000


class SpeechError(Exception):
    """Transcription failed. Messages are safe to show users."""


class AudioFormatError(SpeechError):
    pass


@dataclass(frozen=True)
class Transcription:
    text: str
    language: str | None
    provider: str


class SpeechRecognizer(Protocol):
    name: str

    def transcribe(self, wav_bytes: bytes) -> Transcription:
        """Blocking call; run it off the event loop."""
        ...


def check_wav(wav_bytes: bytes) -> float:
    """Validate 16 kHz mono 16-bit PCM WAV audio and return its duration in seconds."""
    try:
        with wave.open(io.BytesIO(wav_bytes)) as wav:
            channels, width, rate, frames = (
                wav.getnchannels(),
                wav.getsampwidth(),
                wav.getframerate(),
                wav.getnframes(),
            )
    except (wave.Error, EOFError):
        raise AudioFormatError("Audio must be a WAV file") from None
    if (channels, width, rate) != (1, 2, SAMPLE_RATE):
        raise AudioFormatError("Audio must be 16 kHz mono 16-bit PCM WAV")
    if frames == 0:
        raise AudioFormatError("Audio is empty")
    return frames / rate
