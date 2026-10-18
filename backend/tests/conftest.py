import io
import wave

import pytest
from fastapi.testclient import TestClient

from app.agent.planner import Planner
from app.config import Settings
from app.llm.mock import MockLLMProvider
from app.main import create_app
from app.speech.mock import MockSpeechRecognizer
from app.storage.repository import TaskRepository
from app.tasks.manager import TaskManager

TOKEN = "test-token"


class StaticLLM:
    """Returns a fixed raw plan (or raises) so tests control the LLM output."""

    name = "static"

    def __init__(self, plan=None, error: Exception | None = None):
        self.plan, self.error = plan, error

    def propose_plan(self, instruction):
        if self.error:
            raise self.error
        return self.plan


def make_manager(llm=None) -> TaskManager:
    return TaskManager(Planner(llm or MockLLMProvider()), TaskRepository())


def make_client(llm=None) -> TestClient:
    app = create_app(
        settings=Settings(_env_file=None),
        task_manager=make_manager(llm),
        speech_recognizer=MockSpeechRecognizer(),
        api_token=TOKEN,
    )
    return TestClient(app, base_url="http://127.0.0.1")


@pytest.fixture
def client():
    with make_client() as c:
        c.headers["Authorization"] = f"Bearer {TOKEN}"
        yield c


def wav_bytes(seconds: float = 0.5, rate: int = 16_000, channels: int = 1) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"\x00\x00" * int(seconds * rate) * channels)
    return buf.getvalue()
