"""Agent mode: new actions, ignoring non-commands, conversation memory, Groq Whisper."""

import asyncio

import httpx
import pytest

from app.policy.validator import PlanValidationError, validate_plan
from app.speech.base import SpeechError, Transcription
from app.speech.groq_whisper import FallbackRecognizer, GroqWhisperRecognizer, confident_text
from tests.conftest import StaticLLM, make_manager, wav_bytes


def test_close_and_scroll_are_allowed():
    plan = validate_plan({"summary": "", "actions": [
        {"type": "close_application", "parameters": {"application_name": "Calculator"}},
        {"type": "scroll", "parameters": {"direction": "down"}},
    ]})
    assert [a.description for a in plan.actions] == ["Close Calculator", "Scroll down"]
    assert not any(a.requires_approval for a in plan.actions)
    assert plan.actions[1].parameters == {"direction": "down", "amount": 5}


@pytest.mark.parametrize("params", [{"direction": "sideways"}, {"direction": "up", "amount": 500}])
def test_bad_scroll_is_rejected(params):
    with pytest.raises(PlanValidationError):
        validate_plan({"summary": "", "actions": [{"type": "scroll", "parameters": params}]})


async def wait_until_done(manager, task_id):
    for _ in range(100):
        task = manager.get(task_id)
        if task.status.is_terminal or task.status.value == "running" and task.actions:
            return task
        await asyncio.sleep(0.01)
    raise AssertionError("task didn't finish planning")


async def test_background_speech_is_ignored():
    manager = make_manager(StaticLLM({"summary": "", "actions": [], "not_a_command": True}))
    task = await manager.create("so anyway I told him that")
    task = await wait_until_done(manager, task.task_id)
    assert task.status.value == "cancelled"


class RecordingLLM(StaticLLM):
    def __init__(self, plan):
        super().__init__(plan)
        self.prompts = []

    def propose_plan(self, instruction):
        self.prompts.append(instruction)
        return super().propose_plan(instruction)


async def test_session_history_reaches_the_planner():
    llm = RecordingLLM({"summary": "", "actions": [
        {"type": "open_application", "parameters": {"application_name": "Calculator"}}]})
    manager = make_manager(llm)
    first = await manager.create("open calculator", session_id="abcd1234")
    first = await wait_until_done(manager, first.task_id)
    await manager.report_result(first.task_id, first.actions[0].action_id, 1, True, None, None, False)

    second = await manager.create("now close it", session_id="abcd1234")
    await wait_until_done(manager, second.task_id)
    await manager.cancel(second.task_id)
    assert llm.prompts[0] == "open calculator"  # nothing earlier yet
    assert 'User said "open calculator" → done (Open Calculator)' in llm.prompts[1]
    assert llm.prompts[1].endswith("Current instruction: now close it")

    other = await manager.create("hello", session_id="ffff0000")
    await wait_until_done(manager, other.task_id)
    assert llm.prompts[2] == "hello"  # other sessions don't leak in


def groq(handler):
    client = httpx.Client(base_url="https://api.groq.com/openai/v1", transport=httpx.MockTransport(handler))
    return GroqWhisperRecognizer("key", "whisper-large-v3-turbo", client=client)


def test_groq_whisper_sends_audio_and_app_hint():
    seen = {}

    def handler(request):
        seen["body"] = request.content
        return httpx.Response(200, json={"text": " Open Google Chrome. "})

    result = groq(handler).transcribe(wav_bytes())
    assert result.text == "Open Google Chrome." and result.provider == "groq-whisper"
    assert b"whisper-large-v3-turbo" in seen["body"] and b"Apps:" in seen["body"]


def test_invented_and_repeated_text_is_dropped():
    result = {"segments": [
        {"text": " Open calculator.", "avg_logprob": -0.1, "no_speech_prob": 0.0},
        {"text": " Open calculator.", "avg_logprob": -0.2, "no_speech_prob": 0.0},   # echo
        {"text": " Ssutu, Pint Center.", "avg_logprob": -1.5, "no_speech_prob": 0.0},  # noise
        {"text": " Thank you.", "avg_logprob": -0.3, "no_speech_prob": 0.9},  # silence
    ]}
    assert confident_text(result) == "Open calculator."


def test_groq_errors_are_readable():
    with pytest.raises(SpeechError, match="rate limit"):
        groq(lambda r: httpx.Response(429)).transcribe(wav_bytes())


class Local:
    name = "whistle"

    def transcribe(self, wav):
        return Transcription(text="local", language="en", provider=self.name)


def test_offline_falls_back_to_whistle():
    def offline(request):
        raise httpx.ConnectError("no network")

    result = FallbackRecognizer(groq(offline), Local()).transcribe(wav_bytes())
    assert result.provider == "whistle"
