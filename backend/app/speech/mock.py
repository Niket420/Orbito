"""MOCK transcriber used only when Cactus Whistle is not installed.

It ignores the audio and returns a fixed sentence. It reports provider "mock"
so the UI can label the result as not coming from real speech recognition.
"""

from __future__ import annotations

from app.speech.base import Transcription, check_wav

MOCK_TEXT = "Open Safari and search for AI news"


class MockSpeechRecognizer:
    name = "mock"

    def transcribe(self, wav_bytes: bytes) -> Transcription:
        check_wav(wav_bytes)
        return Transcription(text=MOCK_TEXT, language="en", provider=self.name)
