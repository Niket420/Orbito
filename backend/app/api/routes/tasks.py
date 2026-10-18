from typing import Annotated

from fastapi import APIRouter, Depends, Path, status

from app.api.deps import get_task_manager, require_token
from app.api.schemas.requests import ActionResultRequest, ApprovalRequest, CreateTaskRequest
from app.api.schemas.responses import TaskCreatedResponse, TaskResponse
from app.tasks.manager import TaskManager

router = APIRouter(prefix="/tasks", dependencies=[Depends(require_token)])

TaskId = Annotated[str, Path(pattern=r"^[0-9a-f]{32}$")]
ActionId = Annotated[str, Path(pattern=r"^[0-9a-f]{12}$")]
Manager = Annotated[TaskManager, Depends(get_task_manager)]


@router.post("", status_code=status.HTTP_201_CREATED, response_model=TaskCreatedResponse)
async def create_task(body: CreateTaskRequest, manager: Manager) -> TaskCreatedResponse:
    task = await manager.create(body.instruction)
    return TaskCreatedResponse(task_id=task.task_id, status=task.status.value, message=task.message)


@router.get("/{task_id}", response_model=TaskResponse)
async def get_task(task_id: TaskId, manager: Manager) -> TaskResponse:
    return TaskResponse.of(manager.get(task_id))


@router.post("/{task_id}/cancel", response_model=TaskResponse)
async def cancel_task(task_id: TaskId, manager: Manager) -> TaskResponse:
    return TaskResponse.of(await manager.cancel(task_id))


@router.post("/{task_id}/approval", response_model=TaskResponse)
async def approve_task(task_id: TaskId, body: ApprovalRequest, manager: Manager) -> TaskResponse:
    return TaskResponse.of(await manager.set_approval(task_id, body.approved))


@router.post("/{task_id}/actions/{action_id}/result", response_model=TaskResponse)
async def report_action_result(
    task_id: TaskId, action_id: ActionId, body: ActionResultRequest, manager: Manager
) -> TaskResponse:
    task = await manager.report_result(
        task_id,
        action_id,
        attempt=body.attempt,
        success=body.success,
        observation=body.observation,
        error=body.error,
        retryable=body.retryable,
    )
    return TaskResponse.of(task)
