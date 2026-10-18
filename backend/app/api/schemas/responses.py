"""Response bodies. See shared/api-contract.md."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel

from app.tasks.state import Task, TaskAction


class HealthResponse(BaseModel):
    status: str = "ok"
    version: str
    llm_provider: str
    speech_provider: str


class TaskCreatedResponse(BaseModel):
    task_id: str
    status: str
    message: str


class ActionView(BaseModel):
    action_id: str
    type: str
    parameters: dict[str, Any]
    description: str
    requires_approval: bool
    status: str
    attempt: int
    observation: str | None
    error: str | None

    @classmethod
    def of(cls, action: TaskAction) -> "ActionView":
        return cls.model_validate(action.model_dump(mode="json"))


class TaskResponse(BaseModel):
    task_id: str
    instruction: str
    status: str
    message: str
    result: str | None
    error: str | None
    planner: str | None
    actions: list[ActionView]
    next_action: ActionView | None
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, task: Task) -> "TaskResponse":
        nxt = task.next_action
        return cls(
            task_id=task.task_id,
            instruction=task.instruction,
            status=task.status.value,
            message=task.message,
            result=task.result,
            error=task.error,
            planner=task.planner,
            actions=[ActionView.of(a) for a in task.actions],
            next_action=ActionView.of(nxt) if nxt else None,
            created_at=task.created_at,
            updated_at=task.updated_at,
        )


class TranscriptionResponse(BaseModel):
    text: str
    language: str | None
    provider: str
    duration_seconds: float


class ErrorBody(BaseModel):
    code: str
    message: str


class ErrorResponse(BaseModel):
    error: ErrorBody
