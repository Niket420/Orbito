"""Backend entry point: `python -m app.main` (run from the backend directory)."""

from __future__ import annotations

import asyncio
import logging
import os
import signal
import threading
import time
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException
from starlette.middleware.trustedhost import TrustedHostMiddleware

from app.agent.planner import Planner, build_llm_provider
from app.api.routes import health, speech, tasks, voice
from app.config import Settings, get_settings, resolve_api_token
from app.logging.setup import configure_logging
from app.speech.base import AudioFormatError, SpeechError, SpeechRecognizer
from app.speech.cactus_whistle import WhistleRecognizer, whistle_installed
from app.speech.mock import MockSpeechRecognizer
from app.speech.voice_stream import build_voice_stream, prepare_models, voice_installed
from app.storage.repository import TaskRepository
from app.tasks.manager import TaskError, TaskManager

__version__ = "0.1.0"
log = logging.getLogger(__name__)


def build_speech(settings: Settings) -> SpeechRecognizer:
    if settings.speech_provider == "mock":
        return MockSpeechRecognizer()
    if whistle_installed():
        return WhistleRecognizer()
    if settings.speech_provider == "whistle":
        raise RuntimeError("ORBITO_SPEECH_PROVIDER=whistle but cactus-needle is not installed")
    log.warning("speech_fallback_to_mock", extra={"reason": "cactus-needle not installed"})
    return MockSpeechRecognizer()


def _error(status_code: int, code: str, message: str, headers: dict | None = None) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={"error": {"code": code, "message": message}},
        headers=headers,
    )


def _install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(TaskError)
    async def _task_error(_: Request, exc: TaskError) -> JSONResponse:
        return _error(exc.status_code, exc.code, exc.message)

    @app.exception_handler(AudioFormatError)
    async def _audio_error(_: Request, exc: AudioFormatError) -> JSONResponse:
        return _error(422, "invalid_audio", str(exc))

    @app.exception_handler(SpeechError)
    async def _speech_error(_: Request, exc: SpeechError) -> JSONResponse:
        return _error(503, "speech_unavailable", str(exc))

    @app.exception_handler(HTTPException)
    async def _http_error(_: Request, exc: HTTPException) -> JSONResponse:
        code = {401: "unauthorized", 404: "not_found"}.get(exc.status_code, "http_error")
        return _error(exc.status_code, code, str(exc.detail), getattr(exc, "headers", None))

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        first = exc.errors()[0] if exc.errors() else {}
        field = ".".join(str(p) for p in first.get("loc", [])[1:])
        message = str(first.get("msg", "Invalid request")).removeprefix("Value error, ")
        return _error(422, "invalid_request", f"{field}: {message}" if field else message)


def create_app(
    settings: Settings | None = None,
    task_manager: TaskManager | None = None,
    speech_recognizer: SpeechRecognizer | None = None,
    api_token: str | None = None,
    voice_factory=build_voice_stream,
) -> FastAPI:
    settings = settings or get_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if isinstance(app.state.speech, WhistleRecognizer):
            # Warm the model in the background so the first transcription is fast.
            asyncio.get_running_loop().run_in_executor(None, _warm, app.state.speech)
        if voice_installed():
            # Fetch the wake-word and VAD models now rather than when listening starts.
            asyncio.get_running_loop().run_in_executor(None, _prepare_voice, settings.wake_word_model)
        log.info(
            "backend_started",
            extra={"llm": app.state.task_manager.planner_name, "speech": app.state.speech.name},
        )
        yield

    app = FastAPI(title="Orbito Backend", version=__version__, lifespan=lifespan)
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost"])
    app.state.settings = settings
    app.state.voice_factory = voice_factory
    app.state.api_token = api_token or resolve_api_token(settings)
    app.state.speech = speech_recognizer or build_speech(settings)
    app.state.task_manager = task_manager or TaskManager(
        Planner(build_llm_provider(settings)),
        TaskRepository(settings.data_dir / "tasks.json"),
    )
    _install_error_handlers(app)
    app.include_router(health.router)
    app.include_router(tasks.router)
    app.include_router(speech.router)
    app.include_router(voice.router)
    return app


def _warm(recognizer: WhistleRecognizer) -> None:
    try:
        recognizer.load()
    except SpeechError:
        pass  # reported again, with a user-facing message, on first transcription


def _prepare_voice(wake_model: str) -> None:
    try:
        prepare_models(wake_model)
    except Exception as exc:  # noqa: BLE001 - reported again when listening starts
        log.warning("voice_models_unavailable", extra={"error": type(exc).__name__})


def _exit_with_parent(parent_pid: int) -> None:
    """Shut down gracefully if the macOS app that launched us goes away (crash, force quit)."""

    def watch() -> None:
        while True:
            time.sleep(2)
            if os.getppid() != parent_pid:
                log.warning("parent_exited", extra={"parent_pid": parent_pid})
                os.kill(os.getpid(), signal.SIGINT)
                return

    threading.Thread(target=watch, name="parent-watch", daemon=True).start()


def main() -> None:
    settings = get_settings()
    configure_logging(settings.log_level)
    parent = os.environ.get("ORBITO_PARENT_PID", "")
    if parent.isdigit():
        _exit_with_parent(int(parent))
    uvicorn.run(
        create_app(settings),
        host=settings.host,
        port=settings.port,
        log_level=settings.log_level.lower(),
        access_log=False,
    )


if __name__ == "__main__":
    main()
