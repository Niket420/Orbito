"""Full-control actions: validation, risk per parameters, info results and answering."""

import asyncio

import pytest

from app.policy.validator import PlanValidationError, validate_plan
from tests.conftest import StaticLLM, make_manager


def plan(*actions):
    return validate_plan({"summary": "", "actions": [{"type": t, "parameters": p} for t, p in actions]})


def test_risk_depends_on_parameters():
    actions = plan(
        ("click_element", {"target": "Delete account"}),
        ("click_element", {"target": "Sign in"}),
        ("system_control", {"control": "lock_screen"}),
        ("system_control", {"control": "volume_up"}),
        ("trash_selected_files", {}),
        ("app_command", {"command": "new_tab"}),
    ).actions
    assert [a.requires_approval for a in actions] == [True, False, True, False, True, False]


@pytest.mark.parametrize("action", [
    ("app_command", {"command": "quit"}),
    ("open_location", {"location": "documents", "subfolder": "../secret"}),
    ("create_folder", {"name": ".ssh"}),
    ("create_reminder", {"title": "x", "due": "tomorrow at 6"}),
    ("compose_email", {"to": ["nobody"]}),
    ("system_control", {"control": "shutdown"}),
    ("system_control", {"control": "set_volume", "value": 400}),
    ("trash_selected_files", {"path": "/"}),
])
def test_bad_parameters_are_rejected(action):
    with pytest.raises(PlanValidationError):
        plan(action)


async def run_plan(llm, raw_plan, observations):
    llm.plan = raw_plan
    manager = make_manager(llm)
    task = await manager.create("do it")
    for _ in range(100):
        task = manager.get(task.task_id)
        if task.actions:
            break
        await asyncio.sleep(0.01)
    for observation in observations:
        action = task.next_action
        task = await manager.report_result(task.task_id, action.action_id, 1, True, observation, None, False)
        for _ in range(100):
            task = manager.get(task.task_id)
            if task.status.is_terminal or task.next_action:
                break
            await asyncio.sleep(0.01)
    return task


class AnsweringLLM(StaticLLM):
    def __init__(self):
        super().__init__()
        self.asked = []

    def answer(self, question, context):
        self.asked.append((question, context))
        return "It's an article about Nokia."


async def test_info_steps_become_the_result():
    task = await run_plan(StaticLLM(), {"summary": "Checking", "actions": [
        {"type": "get_info", "parameters": {"item": "battery"}}]}, ["Battery is at 80%."])
    assert task.status.value == "completed"
    assert task.result == "Battery is at 80%."


async def test_ask_answers_from_screen_text_then_forgets_it():
    llm = AnsweringLLM()
    task = await run_plan(llm, {"summary": "", "actions": [
        {"type": "ask", "parameters": {"question": "what is this?", "source": "screen"}}]},
        ["Window: Nokia\nThe rise and fall of Nokia"])
    assert task.status.value == "completed"
    assert task.result == "It's an article about Nokia."
    assert llm.asked == [("what is this?", "Window: Nokia\nThe rise and fall of Nokia")]
    assert task.actions[0].observation == "Read 40 characters"  # screen text isn't kept


async def test_failed_answer_fails_the_task():
    class Broken(StaticLLM):
        def answer(self, question, context):
            from app.llm.base import LLMUnavailableError
            raise LLMUnavailableError("Groq is down")

    task = await run_plan(Broken(), {"summary": "", "actions": [
        {"type": "ask", "parameters": {"question": "2+2?"}}]}, [""])
    assert task.status.value == "failed"
    assert task.error == "Groq is down"
