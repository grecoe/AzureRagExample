"""HTTP API for applications: POST /ask, POST /search, GET /healthz.

Access control is layered:
1. Azure Container Apps built-in authentication (Easy Auth) rejects any request without
   a valid Entra token for this API, and its allowedPrincipals policy admits only the
   operator's object ID.
2. This app re-checks X-MS-CLIENT-PRINCIPAL-ID (injected by Easy Auth) against
   ALLOWED_PRINCIPAL_IDS, so a platform misconfiguration still fails closed.
Locally (AUTH_MODE=local), the server binds to 127.0.0.1 only.
"""

from __future__ import annotations

import asyncio
import logging
import time
from contextlib import asynccontextmanager
from typing import Literal

from fastapi import Depends, FastAPI, HTTPException, Request
from pydantic import BaseModel, Field

from .answer import RagService, to_passages
from .clients import async_credential, build_kernel, openai_client
from .config import Settings, load_settings
from .search_store import SearchStore
from .telemetry import configure_telemetry, track_event

log = logging.getLogger("rag.api")
PRINCIPAL_HEADER = "x-ms-client-principal-id"
TRACKED_OPERATIONS = {"/ask": "ask", "/search": "search"}


class AskRequest(BaseModel):
    question: str = Field(min_length=3, max_length=4000)
    mode: Literal["generative", "extractive"] = "generative"


class SearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=4000)


def call_status(http_status: int, outcome: str | None) -> str:
    """Map an HTTP result to the RagApiCall status dimension."""
    if http_status < 400:
        return outcome or "success"
    if http_status in (401, 403):
        return "forbidden"
    return "client_error" if http_status < 500 else "failed"


def note_call(request: Request, **dimensions: str) -> None:
    """Attach outcome details that the tracking middleware adds to the event."""
    request.state.rag_call = {**getattr(request.state, "rag_call", {}), **dimensions}


def authorize(request: Request) -> None:
    settings: Settings = request.app.state.settings
    if settings.auth_mode == "local":
        return
    principal = request.headers.get(PRINCIPAL_HEADER, "").strip().lower()
    if not principal or principal not in settings.allowed_principal_ids:
        raise HTTPException(status_code=403, detail="Forbidden")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = app.state.settings
    credential = async_credential(settings)
    client = openai_client(settings, credential)
    store = SearchStore(settings, credential)
    app.state.rag = RagService(settings, build_kernel(settings, client), store)
    app.state.gate = asyncio.Semaphore(settings.max_concurrent_answers)
    try:
        yield
    finally:
        await store.__aexit__(None, None, None)
        await client.close()
        await credential.close()


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or load_settings()
    configure_telemetry(settings)
    local = settings.auth_mode == "local"
    app = FastAPI(
        title="RAG example API",
        lifespan=lifespan,
        docs_url="/docs" if local else None,
        redoc_url=None,
        openapi_url="/openapi.json" if local else None,
    )
    app.state.settings = settings

    @app.middleware("http")
    async def track_api_calls(request: Request, call_next):
        operation = TRACKED_OPERATIONS.get(request.url.path)
        if operation is None:
            return await call_next(request)
        started = time.perf_counter()
        http_status, error_type = 500, ""
        try:
            response = await call_next(request)
            http_status = response.status_code
            return response
        except Exception as error:
            error_type = type(error).__name__
            raise
        finally:
            details = dict(getattr(request.state, "rag_call", {}))
            outcome = details.pop("outcome", None)
            track_event(
                "RagApiCall",
                call_status(http_status, outcome),
                measurements={"duration_ms": round((time.perf_counter() - started) * 1000, 1)},
                operation=operation,
                http_status=http_status,
                **{"error_type": error_type, **details},
            )

    @app.get("/healthz")
    async def healthz() -> dict:
        return {"status": "ok"}

    @app.post("/ask", dependencies=[Depends(authorize)])
    async def ask(body: AskRequest, request: Request) -> dict:
        if len(body.question) > settings.max_question_chars:
            raise HTTPException(status_code=422, detail="Question is too long")
        async with request.app.state.gate:
            try:
                answer = await request.app.state.rag.ask(body.question, extractive=body.mode == "extractive")
            except Exception as error:  # noqa: BLE001 - never return or log upstream error text
                log.error("ask failed: %s", type(error).__name__)
                note_call(request, error_type=type(error).__name__)
                raise HTTPException(status_code=502, detail="Upstream service error") from None
        outcome = "not_found" if answer.status == "not_found" else "success"
        note_call(request, answer_status=answer.status, outcome=outcome)
        return answer.to_dict()

    @app.post("/search", dependencies=[Depends(authorize)])
    async def search(body: SearchRequest, request: Request) -> dict:
        if len(body.query) > settings.max_question_chars:
            raise HTTPException(status_code=422, detail="Query is too long")
        async with request.app.state.gate:
            try:
                hits = await request.app.state.rag.retrieve(body.query)
            except Exception as error:  # noqa: BLE001
                log.error("search failed: %s", type(error).__name__)
                note_call(request, error_type=type(error).__name__)
                raise HTTPException(status_code=502, detail="Upstream service error") from None
        passages = to_passages(hits)
        note_call(request, outcome="success" if passages else "not_found")
        return {"passages": [p.__dict__ for p in passages]}

    return app
