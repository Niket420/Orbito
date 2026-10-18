import asyncio

import pytest

from app.agent.planner import Planner
from app.llm.base import LLMThrottledError
from app.storage.repository import TaskRepository
from app.tasks.manager import TaskError, TaskManager
from app.tasks.state import ActionStatus, Task, TaskStatus
from tests.conftest import StaticLLM, make_manager

OPEN_SAFARI = {"type": "open_application", "parameters": {"application_name": "Safari"}}
SEARCH = {"type": "search_web", "parameters": {"query": "AI news"}}


async def planned(manager: TaskManager, instruction: str = "do it") -> Task:
    task = await manager.create(instruction)
    for _ in range(100):
        await asyncio.sleep(0)
        if task.status is not TaskStatus.PENDING and task.message != "Thinking about how to do that…":
            break
    return manager.get(task.task_id)


async def report(manager, task, success=True, retryable=False, error=None):
    action = task.next_action
    return await manager.report_result(
        task.task_id, action.action_id, action.attempt, success, None, error, retryable
    )


async def test_completes_after_all_actions_succeed():
    manager = make_manager(StaticLLM({"summary": "Searching", "actions": [OPEN_SAFARI, SEARCH]}))
    task = await planned(manager)
    assert task.status is TaskStatus.RUNNING
    assert task.message == "Step 1 of 2: Open Safari"
    task = await report(manager, task)
    assert task.message.startswith("Step 2 of 2")
    task = await report(manager, task)
    assert task.status is TaskStatus.COMPLETED
    assert task.result == "Searching"


async def test_llm_error_fails_task_with_readable_message():
    manager = make_manager(StaticLLM(error=LLMThrottledError("Bedrock is busy right now.")))
    task = await planned(manager)
    assert task.status is TaskStatus.FAILED
    assert task.error == "Bedrock is busy right now."


async def test_invalid_plan_fails_task():
    manager = make_manager(StaticLLM({"actions": [{"type": "run_shell", "parameters": {}}]}))
    task = await planned(manager)
    assert task.status is TaskStatus.FAILED
    assert "unsupported action" in task.error


async def test_retry_safe_action_is_retried_once():
    manager = make_manager(StaticLLM({"actions": [OPEN_SAFARI]}))
    task = await planned(manager)
    task = await report(manager, task, success=False, retryable=True, error="not running yet")
    assert task.status is TaskStatus.RUNNING
    assert task.next_action.attempt == 2
    task = await report(manager, task, success=False, retryable=True, error="still not running")
    assert task.status is TaskStatus.FAILED
    assert "Couldn't open Safari" in task.error


async def test_non_retry_safe_action_fails_immediately():
    manager = make_manager(StaticLLM({"actions": [SEARCH, OPEN_SAFARI]}))
    task = await planned(manager)
    task = await report(manager, task, success=False, retryable=True)
    assert task.status is TaskStatus.FAILED
    assert task.actions[1].status is ActionStatus.SKIPPED


async def test_cannot_approve_when_not_waiting():
    manager = make_manager(StaticLLM({"actions": [OPEN_SAFARI]}))
    task = await planned(manager)
    with pytest.raises(TaskError):
        await manager.set_approval(task.task_id, True)


async def test_cancel_during_planning():
    started = asyncio.Event()

    class SlowLLM:
        name = "slow"

        def propose_plan(self, instruction):
            started.set()
            import time

            time.sleep(0.2)
            return {"actions": [OPEN_SAFARI]}

    manager = make_manager(SlowLLM())
    task = await manager.create("x")
    await asyncio.sleep(0.05)
    task = await manager.cancel(task.task_id)
    assert task.status is TaskStatus.CANCELLED
    await asyncio.sleep(0.3)
    assert manager.get(task.task_id).status is TaskStatus.CANCELLED


async def test_persistence_and_restart_recovery(tmp_path):
    path = tmp_path / "tasks.json"
    manager = TaskManager(Planner(StaticLLM({"actions": [OPEN_SAFARI]})), TaskRepository(path))
    task = await planned(manager)
    assert task.status is TaskStatus.RUNNING
    assert oct(path.stat().st_mode & 0o777) == "0o600"

    # Simulate a backend restart: the in-flight task must not be resumed.
    restarted = TaskManager(Planner(StaticLLM({"actions": []})), TaskRepository(path))
    recovered = restarted.get(task.task_id)
    assert recovered.status is TaskStatus.FAILED
    assert recovered.actions[0].status is ActionStatus.SKIPPED
    assert restarted.active_task() is None
