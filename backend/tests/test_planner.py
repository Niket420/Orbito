from unittest.mock import MagicMock

import pytest
from botocore.exceptions import ClientError, NoCredentialsError, ReadTimeoutError

from app.agent.instruction_parser import InstructionError, normalize_instruction
from app.llm.base import LLMAuthError, LLMResponseError, LLMThrottledError, LLMTimeoutError
from app.llm.bedrock import BedrockProvider, extract_plan
from app.llm.mock import MockLLMProvider
from app.policy.validator import PlanValidationError, validate_plan


# ----- validator -----------------------------------------------------------------

def test_valid_plan():
    plan = validate_plan(
        {
            "summary": "Open Safari",
            "actions": [
                {"type": "open_application", "parameters": {"application_name": "Safari"}},
                {"type": "type_text", "parameters": {"text": "latest AI news"}},
            ],
        }
    )
    assert [a.type.value for a in plan.actions] == ["open_application", "type_text"]
    assert not plan.actions[0].requires_approval
    assert plan.actions[1].requires_approval


@pytest.mark.parametrize(
    "action",
    [
        {"type": "run_shell", "parameters": {"command": "rm -rf ~"}},
        {"type": "open_application", "parameters": {}},
        {"type": "open_application", "parameters": {"application_name": "Safari; rm -rf /"}},
        {"type": "open_application", "parameters": {"application_name": "Safari", "extra": 1}},
        {"type": "open_url", "parameters": {"url": "file:///etc/passwd"}},
        {"type": "open_url", "parameters": {"url": "javascript:alert(1)"}},
        {"type": "press_key", "parameters": {"key": "q", "modifiers": ["command"]}},
        {"type": "press_key", "parameters": {"key": "escape", "modifiers": ["command", "option"]}},
        {"type": "press_key", "parameters": {"key": "f13"}},
        {"type": "press_key", "parameters": {"key": "a", "modifiers": ["hyper"]}},
        {"type": "type_text", "parameters": {"text": "x" * 501}},
        "open_application",
    ],
)
def test_rejects_unsafe_or_malformed_actions(action):
    with pytest.raises(PlanValidationError):
        validate_plan({"summary": "", "actions": [action]})


def test_rejects_too_many_steps():
    step = {"type": "open_application", "parameters": {"application_name": "Notes"}}
    with pytest.raises(PlanValidationError):
        validate_plan({"actions": [step] * 9})


def test_rejects_non_object_plan():
    with pytest.raises(PlanValidationError):
        validate_plan(["not", "a", "plan"])


# ----- instruction parser ------------------------------------------------------

def test_normalize_instruction():
    assert normalize_instruction("  open\x00  Safari \n") == "open Safari"
    with pytest.raises(InstructionError):
        normalize_instruction("\x07  ")
    with pytest.raises(InstructionError):
        normalize_instruction("a" * 1001)


# ----- mock planner ------------------------------------------------------------

@pytest.mark.parametrize(
    "instruction, expected",
    [
        ("Open Safari and search for AI news.", ["open_application", "search_web"]),
        ("open vs code", ["open_application"]),
        ("go to apple.com", ["open_url"]),
        ("open chrome then go to github.com", ["open_application", "open_url"]),
        ("search for cats and dogs", ["search_web"]),
        ("press cmd+t", ["press_key"]),
    ],
)
def test_mock_planner_output_passes_validation(instruction, expected):
    plan = validate_plan(MockLLMProvider().propose_plan(instruction))
    assert [a.type.value for a in plan.actions] == expected


def test_mock_planner_uses_named_browser():
    plan = validate_plan(MockLLMProvider().propose_plan("open chrome and search for weather"))
    assert plan.actions[1].parameters == {"query": "weather", "application_name": "Google Chrome"}


def test_mock_planner_reports_unsupported():
    plan = validate_plan(MockLLMProvider().propose_plan("delete all my files"))
    assert plan.actions == []
    assert plan.unsupported_reason


# ----- Bedrock -----------------------------------------------------------------

def _tool_response(plan):
    return {"output": {"message": {"content": [{"toolUse": {"name": "propose_plan", "input": plan}}]}}}


def _client_error(code):
    return ClientError({"Error": {"Code": code, "Message": "x"}}, "Converse")


def test_bedrock_extracts_tool_plan():
    client = MagicMock()
    plan = {"summary": "s", "actions": []}
    client.converse.return_value = _tool_response(plan)
    assert BedrockProvider("model", "us-east-1", client=client).propose_plan("hi") == plan
    kwargs = client.converse.call_args.kwargs
    assert kwargs["modelId"] == "model"
    assert kwargs["toolConfig"]["toolChoice"] == {"any": {}}


def test_bedrock_retries_without_tool_choice_when_unsupported():
    client = MagicMock()
    err = ClientError(
        {"Error": {"Code": "ValidationException", "Message": "toolChoice is not supported"}}, "Converse"
    )
    client.converse.side_effect = [err, _tool_response({"actions": []})]
    BedrockProvider("model", "us-east-1", client=client).propose_plan("hi")
    assert "toolChoice" not in client.converse.call_args.kwargs["toolConfig"]


@pytest.mark.parametrize(
    "error, expected",
    [
        (_client_error("AccessDeniedException"), LLMAuthError),
        (_client_error("ThrottlingException"), LLMThrottledError),
        (NoCredentialsError(), LLMAuthError),
        (ReadTimeoutError(endpoint_url="x"), LLMTimeoutError),
    ],
)
def test_bedrock_maps_errors(error, expected):
    client = MagicMock()
    client.converse.side_effect = error
    with pytest.raises(expected):
        BedrockProvider("model", "us-east-1", client=client).propose_plan("hi")


def test_extract_plan_text_fallback_and_malformed():
    text = {"output": {"message": {"content": [{"text": 'Sure: {"summary": "x", "actions": []}'}]}}}
    assert extract_plan(text) == {"summary": "x", "actions": []}
    with pytest.raises(LLMResponseError):
        extract_plan({"output": {"message": {"content": [{"text": "no json here"}]}}})
    with pytest.raises(LLMResponseError):
        extract_plan({"unexpected": True})


# ----- Groq --------------------------------------------------------------------

import json as _json

import httpx

from app.agent.planner import build_llm_provider
from app.config import Settings
from app.llm.groq import GroqProvider


def _groq(handler):
    client = httpx.Client(base_url="https://api.groq.com/openai/v1", transport=httpx.MockTransport(handler))
    return GroqProvider("key", "openai/gpt-oss-120b", client=client)


def _tool_call(plan):
    message = {"role": "assistant", "tool_calls": [
        {"id": "1", "type": "function", "function": {"name": "propose_plan", "arguments": _json.dumps(plan)}}]}
    return httpx.Response(200, json={"choices": [{"message": message}]})


def test_groq_returns_tool_call_plan():
    seen = {}

    def handler(request):
        seen.update(_json.loads(request.content))
        return _tool_call({"summary": "s", "actions": []})

    assert _groq(handler).propose_plan("hi") == {"summary": "s", "actions": []}
    assert seen["model"] == "openai/gpt-oss-120b"
    assert seen["tool_choice"]["function"]["name"] == "propose_plan"


def test_groq_retries_rate_limit_then_succeeds(monkeypatch):
    monkeypatch.setattr("app.llm.groq.time.sleep", lambda s: None)
    responses = iter([httpx.Response(429, headers={"retry-after": "0"}), _tool_call({"actions": []})])
    assert _groq(lambda r: next(responses)).propose_plan("hi") == {"actions": []}


@pytest.mark.parametrize(
    "response, expected",
    [
        (httpx.Response(401, json={"error": {"code": "invalid_api_key"}}), LLMAuthError),
        (httpx.Response(429, json={"error": {"code": "rate_limit_exceeded"}}), LLMThrottledError),
        (httpx.Response(400, json={"error": {"code": "tool_use_failed"}}), LLMResponseError),
        (httpx.Response(200, json={"choices": [{"message": {"content": "no plan"}}]}), LLMResponseError),
        (httpx.Response(200, json={"unexpected": True}), LLMResponseError),
    ],
)
def test_groq_maps_errors(monkeypatch, response, expected):
    monkeypatch.setattr("app.llm.groq.time.sleep", lambda s: None)
    with pytest.raises(expected):
        _groq(lambda r: response).propose_plan("hi")


def test_groq_timeout():
    def handler(request):
        raise httpx.ReadTimeout("slow", request=request)

    with pytest.raises(LLMTimeoutError):
        _groq(handler).propose_plan("hi")


def test_provider_selection(monkeypatch):
    for var in ("GROQ_API_KEY", "AWS_BEARER_TOKEN_BEDROCK", "AWS_ACCESS_KEY_ID", "AWS_PROFILE"):
        monkeypatch.delenv(var, raising=False)
    base = dict(_env_file=None, bedrock_model_id=None)
    assert build_llm_provider(Settings(**base)).name == "mock"
    groq = Settings(**base, GROQ_API_KEY="gsk_SECRET123", groq_model_id="m")
    assert build_llm_provider(groq).name == "groq"
    assert "gsk_SECRET123" not in repr(groq)
    with pytest.raises(RuntimeError):
        build_llm_provider(Settings(**base, llm_provider="groq"))


def test_env_file_key_names_are_case_insensitive(tmp_path):
    env = tmp_path / ".env"
    env.write_text("groq_api_key=abc\nORBITO_GROQ_MODEL_ID=m\nAWS_REGION=\n")
    s = Settings(_env_file=env)
    assert s.groq_api_key.get_secret_value() == "abc"
    assert s.aws_region is None


# ----- plan schema & retry -----------------------------------------------------

from app.agent.planner import Planner
from app.agent.prompts import PLAN_TOOL_SCHEMA
from app.policy.permissions import ACTION_SPECS


def test_tool_schema_requires_each_actions_parameters():
    options = PLAN_TOOL_SCHEMA["properties"]["actions"]["items"]["anyOf"]
    by_type = {o["properties"]["type"]["enum"][0]: o["properties"]["parameters"] for o in options}
    assert set(by_type) == {t.value for t in ACTION_SPECS}
    assert by_type["open_application"]["required"] == ["application_name"]
    assert by_type["search_web"]["required"] == ["query"]
    assert "application_name" in by_type["search_web"]["properties"]
    assert all(p["additionalProperties"] is False for p in by_type.values())


class SequenceLLM:
    name = "seq"

    def __init__(self, *plans):
        self.plans, self.prompts = list(plans), []

    def propose_plan(self, instruction):
        self.prompts.append(instruction)
        return self.plans.pop(0)


async def test_planner_retries_rejected_plan_with_feedback():
    bad = {"actions": [{"type": "open_application", "parameters": {}}]}
    good = {"actions": [{"type": "open_application", "parameters": {"application_name": "Google Chrome"}}]}
    llm = SequenceLLM(bad, good)
    plan = await Planner(llm).plan("Open Chrome")
    assert plan.actions[0].parameters == {"application_name": "Google Chrome"}
    assert "is missing “application_name”" in llm.prompts[1]


async def test_planner_gives_up_after_one_retry():
    bad = {"actions": [{"type": "open_application", "parameters": {}}]}
    with pytest.raises(PlanValidationError, match="is missing “application_name”"):
        await Planner(SequenceLLM(bad, bad)).plan("Open Chrome")
