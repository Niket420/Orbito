import json

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.speech.mock import MockSpeechRecognizer
from app.speech.voice_stream import CHUNK, Mode, VoiceStream, matches_phrase
from tests.conftest import TOKEN, make_manager


class FakeScorer:
    """Returns scores from a queue; 0 once it runs out."""

    def __init__(self, scores=()):
        self.scores = list(scores)
        self.resets = 0

    def score(self, chunk):
        return self.scores.pop(0) if self.scores else 0.0

    def reset(self):
        self.resets += 1


def chunks(n: int) -> bytes:
    return np.zeros(CHUNK * n, dtype="<i2").tobytes()


def test_wake_word_is_double_checked_before_listening():
    stream = VoiceStream(FakeScorer([0.1, 0.9]), FakeScorer())
    stream.set_mode(Mode.WAKE)
    events = stream.feed(chunks(2))
    assert [e.kind for e in events] == ["candidate"]
    assert stream.mode == Mode.VERIFYING

    assert [e.kind for e in stream.verified(True)] == ["wake"]
    assert stream.mode == Mode.COMMAND


def test_rejected_wake_word_goes_back_to_waiting():
    wake = FakeScorer([0.9])
    stream = VoiceStream(wake, FakeScorer())
    stream.set_mode(Mode.WAKE)
    stream.feed(chunks(1))
    assert stream.verified(False) == []
    assert stream.mode == Mode.WAKE
    assert wake.resets >= 2  # model state cleared so it doesn't re-fire


def test_command_ends_after_a_pause():
    # 5 chunks of speech, then silence until the end-of-speech pause (0.9 s ≈ 12 chunks).
    stream = VoiceStream(None, FakeScorer([0.9] * 5))
    stream.set_mode(Mode.COMMAND)
    assert stream.feed(chunks(10)) == []
    events = stream.feed(chunks(10))
    assert [e.kind for e in events] == ["utterance"]
    assert len(events[0].audio) == CHUNK * 17  # everything up to the pause
    assert stream.mode == Mode.IDLE


def test_silence_only_reports_no_speech():
    stream = VoiceStream(None, FakeScorer())
    stream.set_mode(Mode.COMMAND)
    events = stream.feed(chunks(80))  # > 6 s
    assert [e.kind for e in events] == ["no_speech"]


def test_finish_ends_the_command_immediately():
    stream = VoiceStream(None, FakeScorer([0.9, 0.9]))
    stream.set_mode(Mode.COMMAND)
    stream.feed(chunks(2))
    assert [e.kind for e in stream.finish()] == ["utterance"]


def test_without_a_wake_model_wake_mode_is_off():
    stream = VoiceStream(None, FakeScorer())
    stream.set_mode(Mode.WAKE)
    assert stream.mode == Mode.IDLE
    assert not stream.wake_available


@pytest.mark.parametrize(
    ("heard", "phrase", "ok"),
    [
        ("Hey Jarvis.", "hey jarvis", True),
        ("hey jarvis open chrome", "hey jarvis", True),
        ("Hey Charles,", "hey jarvis", False),
        ("hey orbit oh", "hey orbito", True),
        ("hey robert", "hey orbito", False),
    ],
)
def test_phrase_matching(heard, phrase, ok):
    assert matches_phrase(heard, phrase) is ok


# --- WebSocket ---------------------------------------------------------------------


@pytest.fixture
def voice_client():
    def factory(model, threshold):
        return VoiceStream(None, FakeScorer([0.9] * 3))

    app = create_app(settings=Settings(_env_file=None), task_manager=make_manager(),
                     speech_recognizer=MockSpeechRecognizer(), api_token=TOKEN, voice_factory=factory)
    return TestClient(app, base_url="http://127.0.0.1")


def test_stream_requires_the_token(voice_client):
    from starlette.websockets import WebSocketDisconnect

    with pytest.raises(WebSocketDisconnect):
        with voice_client.websocket_connect("ws://127.0.0.1/voice/stream") as ws:
            ws.receive_json()


def test_stream_transcribes_a_command(voice_client):
    headers = {"Authorization": f"Bearer {TOKEN}"}
    with voice_client.websocket_connect("ws://127.0.0.1/voice/stream", headers=headers) as ws:
        ready = ws.receive_json()
        assert ready["type"] == "ready" and ready["wake_available"] is False
        ws.send_text(json.dumps({"mode": "command"}))
        ws.send_bytes(chunks(20))
        assert ws.receive_json() == {"type": "transcribing"}
        transcript = ws.receive_json()
        assert transcript["type"] == "transcript" and transcript["text"]
