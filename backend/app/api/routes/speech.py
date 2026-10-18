import asyncio
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, status

from app.api.deps import get_speech, require_token
from app.api.schemas.responses import TranscriptionResponse
from app.speech.base import SpeechRecognizer, check_wav

router = APIRouter(prefix="/speech", dependencies=[Depends(require_token)])

MAX_AUDIO_BYTES = 10 * 1024 * 1024  # ~5 minutes of 16 kHz mono 16-bit audio


@router.post("/transcribe", response_model=TranscriptionResponse)
async def transcribe(
    request: Request, speech: Annotated[SpeechRecognizer, Depends(get_speech)]
) -> TranscriptionResponse:
    if request.headers.get("content-type", "").split(";")[0] not in {"audio/wav", "audio/x-wav"}:
        raise HTTPException(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, "Send audio/wav")
    audio = await request.body()
    if len(audio) > MAX_AUDIO_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "Recording is too long")

    duration = check_wav(audio)
    result = await asyncio.to_thread(speech.transcribe, audio)
    return TranscriptionResponse(
        text=result.text,
        language=result.language,
        provider=result.provider,
        duration_seconds=round(duration, 2),
    )
