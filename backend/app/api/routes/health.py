from fastapi import APIRouter, Request

from app.api.schemas.responses import HealthResponse

router = APIRouter()


@router.get("/health", response_model=HealthResponse)
def health(request: Request) -> HealthResponse:
    state = request.app.state
    return HealthResponse(
        version=request.app.version,
        llm_provider=state.task_manager.planner_name,
        speech_provider=state.speech.name,
    )
