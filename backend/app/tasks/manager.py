"""Task orchestration.

Lifecycle: a task is created PENDING, planned (RUNNING), then each validated
action is handed to the macOS app one at a time via `next_action`. Actions that
need approval pause the task in WAITING_FOR_APPROVAL. The app reports each
action's outcome; the manager advances, retries (when safe) or fails the task.
Only one task may be active at a time.
"""

from __future__ import annotations

import asyncio
import logging

from app.agent.planner import Planner
from app.llm.base import LLMError
from app.policy.validator import PlanValidationError
from app.storage.repository import TaskRepository
from app.tasks import recovery
from app.tasks.state import ActionStatus, Task, TaskAction, TaskStatus

log = logging.getLogger(__name__)


class TaskError(Exception):
    """A request that conflicts with the task's current state."""

    def __init__(self, message: str, code: str = "conflict", status_code: int = 409) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.status_code = status_code


class TaskNotFound(TaskError):
    def __init__(self) -> None:
        super().__init__("Task not found", code="not_found", status_code=404)


class TaskManager:
    def __init__(self, planner: Planner, repository: TaskRepository) -> None:
        self._planner = planner
        self._repo = repository
        self._lock = asyncio.Lock()
        self._planning: dict[str, asyncio.Task[None]] = {}
        for task in repository.all():
            if recovery.recover_interrupted(task):
                repository.save(task)

    @property
    def planner_name(self) -> str:
        return self._planner.provider_name

    # ----- queries -----------------------------------------------------------

    def get(self, task_id: str) -> Task:
        task = self._repo.get(task_id)
        if task is None:
            raise TaskNotFound()
        return task

    def active_task(self) -> Task | None:
        return next((t for t in self._repo.all() if not t.status.is_terminal), None)

    # ----- commands ----------------------------------------------------------

    async def create(self, instruction: str) -> Task:
        async with self._lock:
            if self.active_task():
                raise TaskError("Another task is still running. Cancel it first.", code="task_active")
            task = Task(instruction=instruction, planner=self._planner.provider_name)
            self._save(task)
        self._planning[task.task_id] = asyncio.create_task(self._plan(task.task_id))
        log.info("task_created", extra={"task_id": task.task_id, "chars": len(instruction)})
        return task

    async def cancel(self, task_id: str) -> Task:
        async with self._lock:
            task = self.get(task_id)
            if task.status.is_terminal:
                return task
            planning = self._planning.pop(task_id, None)
            if planning:
                planning.cancel()
            task.status = TaskStatus.CANCELLED
            task.message = "Cancelled"
            for action in task.actions:
                if action.status not in {ActionStatus.SUCCEEDED, ActionStatus.FAILED}:
                    action.status = ActionStatus.SKIPPED
            self._save(task)
        log.info("task_cancelled", extra={"task_id": task_id})
        return task

    async def set_approval(self, task_id: str, approved: bool) -> Task:
        async with self._lock:
            task = self.get(task_id)
            action = task.current_action
            if task.status is not TaskStatus.WAITING_FOR_APPROVAL or action is None:
                raise TaskError("This task is not waiting for approval.")
            if not approved:
                task.status = TaskStatus.CANCELLED
                task.message = "You declined the next step, so I stopped."
                action.status = ActionStatus.SKIPPED
                for rest in task.actions:
                    if rest.status is ActionStatus.QUEUED:
                        rest.status = ActionStatus.SKIPPED
            else:
                action.approved = True
                self._advance(task)
            self._save(task)
        log.info("task_approval", extra={"task_id": task_id, "approved": approved})
        return task

    async def report_result(
        self,
        task_id: str,
        action_id: str,
        attempt: int,
        success: bool,
        observation: str | None,
        error: str | None,
        retryable: bool,
    ) -> Task:
        async with self._lock:
            task = self.get(task_id)
            action = task.next_action
            if action is None or action.action_id != action_id or action.attempt != attempt:
                raise TaskError("That action is not the one currently running.")

            action.observation = observation
            if success:
                action.status = ActionStatus.SUCCEEDED
                action.error = None
                self._advance(task)
            else:
                self._handle_failure(task, action, error, retryable)
            self._save(task)
        log.info(
            "action_reported",
            extra={"task_id": task_id, "action": action.type, "success": success, "status": task.status.value},
        )
        return task

    # ----- internals ---------------------------------------------------------

    async def _plan(self, task_id: str) -> None:
        async with self._lock:
            task = self.get(task_id)
            task.status = TaskStatus.RUNNING
            task.message = "Thinking about how to do that…"
            self._save(task)

        try:
            plan = await self._planner.plan(task.instruction)
            failure = None
        except (LLMError, PlanValidationError) as exc:
            plan, failure = None, str(exc)
        except asyncio.CancelledError:
            return
        except Exception:  # noqa: BLE001 - never leave a task stuck in RUNNING
            log.exception("planning_crashed", extra={"task_id": task_id})
            plan, failure = None, "Something went wrong while planning."

        async with self._lock:
            self._planning.pop(task_id, None)
            task = self.get(task_id)
            if task.status.is_terminal:  # cancelled while planning
                return
            if plan is not None and not plan.actions:
                failure = plan.unsupported_reason or "I couldn't find a supported way to do that."
            if failure:
                task.status = TaskStatus.FAILED
                task.error = failure
                task.message = "Couldn't plan this task"
            else:
                task.summary = plan.summary or None
                task.actions = [
                    TaskAction(
                        type=a.type.value,
                        parameters=a.parameters,
                        description=a.description,
                        risk=a.risk.value,
                        requires_approval=a.requires_approval,
                        retry_safe=a.retry_safe,
                    )
                    for a in plan.actions
                ]
                self._advance(task)
            self._save(task)

    def _advance(self, task: Task) -> None:
        action = task.current_action
        if action is None:
            task.status = TaskStatus.COMPLETED
            task.message = "All done!"
            task.result = task.summary or " → ".join(a.description for a in task.actions)
            return
        step = task.actions.index(action) + 1
        prefix = f"Step {step} of {len(task.actions)}"
        if action.requires_approval and not action.approved:
            task.status = TaskStatus.WAITING_FOR_APPROVAL
            action.status = ActionStatus.AWAITING_APPROVAL
            task.message = f"{prefix}: approve “{action.description}”?"
        else:
            task.status = TaskStatus.RUNNING
            action.status = ActionStatus.READY
            task.message = f"{prefix}: {action.description}"

    def _handle_failure(self, task: Task, action: TaskAction, error: str | None, retryable: bool) -> None:
        action.error = error
        if recovery.decide(action, retryable) is recovery.RecoveryDecision.RETRY:
            action.attempt += 1
            action.status = ActionStatus.READY
            task.message = f"Retrying: {action.description}"
            return
        action.status = ActionStatus.FAILED
        for rest in task.actions:
            if rest.status is ActionStatus.QUEUED:
                rest.status = ActionStatus.SKIPPED
        task.status = TaskStatus.FAILED
        task.error = recovery.failure_message(action, error)
        task.message = "A step failed"

    def _save(self, task: Task) -> None:
        task.touch()
        self._repo.save(task)
