"""Failure classification and recovery decisions.

Retries happen only for actions that are safe to repeat (no duplicate side
effects) and only when the macOS app reports the failure as transient.
"""

from __future__ import annotations

from enum import Enum

from app.tasks.state import ActionStatus, Task, TaskAction, TaskStatus

MAX_ATTEMPTS = 2


class RecoveryDecision(str, Enum):
    RETRY = "retry"
    FAIL = "fail"


def decide(action: TaskAction, retryable: bool) -> RecoveryDecision:
    if action.retry_safe and retryable and action.attempt < MAX_ATTEMPTS:
        return RecoveryDecision.RETRY
    return RecoveryDecision.FAIL


def failure_message(action: TaskAction, error: str | None) -> str:
    detail = f": {error}" if error else ""
    return f"Couldn't {action.description[0].lower()}{action.description[1:]}{detail}"


def recover_interrupted(task: Task) -> bool:
    """Mark a task left active by a previous backend run as failed.

    Partially-executed plans are never resumed automatically, because a step
    may have run without its result being recorded.
    """
    if task.status.is_terminal:
        return False
    task.status = TaskStatus.FAILED
    task.error = "The assistant restarted before this task finished."
    task.message = "Interrupted"
    for action in task.actions:
        if action.status not in {ActionStatus.SUCCEEDED, ActionStatus.FAILED}:
            action.status = ActionStatus.SKIPPED
    task.touch()
    return True
