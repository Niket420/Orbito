"""Task and action state models."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


def _now() -> datetime:
    return datetime.now(timezone.utc)


class TaskStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    WAITING_FOR_APPROVAL = "waiting_for_approval"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"

    @property
    def is_terminal(self) -> bool:
        return self in {TaskStatus.COMPLETED, TaskStatus.FAILED, TaskStatus.CANCELLED}


class ActionStatus(str, Enum):
    QUEUED = "queued"  # not reached yet
    AWAITING_APPROVAL = "awaiting_approval"
    READY = "ready"  # the macOS app should execute it now
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    SKIPPED = "skipped"


class TaskAction(BaseModel):
    action_id: str = Field(default_factory=lambda: uuid.uuid4().hex[:12])
    type: str
    parameters: dict[str, Any]
    description: str
    risk: str
    requires_approval: bool
    retry_safe: bool
    approved: bool = False
    status: ActionStatus = ActionStatus.QUEUED
    attempt: int = 1
    observation: str | None = None
    error: str | None = None


class Task(BaseModel):
    task_id: str = Field(default_factory=lambda: uuid.uuid4().hex)
    instruction: str
    status: TaskStatus = TaskStatus.PENDING
    message: str = "Task created"
    result: str | None = None
    error: str | None = None
    planner: str | None = None
    summary: str | None = None
    session_id: str | None = None
    actions: list[TaskAction] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=_now)
    updated_at: datetime = Field(default_factory=_now)

    def touch(self) -> None:
        self.updated_at = _now()

    @property
    def current_action(self) -> TaskAction | None:
        return next(
            (a for a in self.actions if a.status is not ActionStatus.SUCCEEDED),
            None,
        )

    @property
    def next_action(self) -> TaskAction | None:
        """The action the macOS app should execute right now, if any."""
        action = self.current_action
        if self.status is TaskStatus.RUNNING and action and action.status is ActionStatus.READY:
            return action
        return None
