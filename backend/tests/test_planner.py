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
