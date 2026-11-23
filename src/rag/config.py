"""Typed settings read from environment variables.

Bicep sets these on the Container App and Job. For local runs, `azd env get-values`
provides the same names (see src/README.md).
"""

from __future__ import annotations

import os
from dataclasses import dataclass

AUTH_MODES = ("local", "easyauth")
SOURCE_KINDS = ("local", "git")


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable {name}")
    return value


def _int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, "").strip()
    value = int(raw) if raw else default
    if not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be between {minimum} and {maximum}")
    return value


def _float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    return float(raw) if raw else default


def _csv(name: str) -> tuple[str, ...]:
    return tuple(v.strip().lower() for v in os.environ.get(name, "").split(",") if v.strip())


@dataclass(frozen=True)
class Settings:
    role: str
    search_endpoint: str
    search_index: str
    openai_endpoint: str
    embedding_deployment: str
    embedding_dimensions: int
    chat_deployment: str
    managed_identity_client_id: str
    appinsights_connection_string: str
    auth_mode: str
    allowed_principal_ids: tuple[str, ...]
    top_k: int
    min_reranker_score: float
    max_question_chars: int
    max_completion_tokens: int
    reasoning_effort: str
    max_concurrent_answers: int
    source_kind: str
    source_path: str
    git_url: str
    git_ref: str
    git_include: str
    git_allowed_hosts: tuple[str, ...]
    max_delete_fraction: float

    @property
    def running_in_azure(self) -> bool:
        # Container Apps sets CONTAINER_APP_NAME for apps and CONTAINER_APP_JOB_NAME for jobs.
        return bool(os.environ.get("CONTAINER_APP_NAME") or os.environ.get("CONTAINER_APP_JOB_NAME"))


def load_settings() -> Settings:
    settings = Settings(
        role=os.environ.get("RAG_ROLE", "api").strip().lower(),
        search_endpoint=_required("AZURE_SEARCH_ENDPOINT").rstrip("/"),
        search_index=_required("AZURE_SEARCH_INDEX"),
        openai_endpoint=_required("AZURE_OPENAI_ENDPOINT").rstrip("/"),
        embedding_deployment=_required("AZURE_OPENAI_EMBEDDING_DEPLOYMENT"),
        embedding_dimensions=_int("AZURE_OPENAI_EMBEDDING_DIMENSIONS", 3072, 256, 3072),
        chat_deployment=_required("AZURE_OPENAI_CHAT_DEPLOYMENT"),
        managed_identity_client_id=os.environ.get("AZURE_CLIENT_ID", "").strip(),
        appinsights_connection_string=os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING", "").strip(),
        auth_mode=os.environ.get("AUTH_MODE", "local").strip().lower(),
        allowed_principal_ids=_csv("ALLOWED_PRINCIPAL_IDS"),
        top_k=_int("RAG_TOP_K", 5, 1, 20),
        min_reranker_score=_float("RAG_MIN_RERANKER_SCORE", 1.5),
        max_question_chars=_int("RAG_MAX_QUESTION_CHARS", 1000, 50, 4000),
        max_completion_tokens=_int("RAG_MAX_COMPLETION_TOKENS", 4000, 256, 32000),
        reasoning_effort=os.environ.get("RAG_REASONING_EFFORT", "low").strip().lower(),
        max_concurrent_answers=_int("RAG_MAX_CONCURRENT_ANSWERS", 4, 1, 64),
        source_kind=os.environ.get("RAG_SOURCE_KIND", "local").strip().lower(),
        source_path=os.environ.get("RAG_SOURCE_PATH", "sample-data").strip(),
        git_url=os.environ.get("RAG_GIT_URL", "").strip(),
        git_ref=os.environ.get("RAG_GIT_REF", "main").strip(),
        git_include=os.environ.get("RAG_GIT_INCLUDE", "**/*.md").strip(),
        git_allowed_hosts=_csv("RAG_GIT_ALLOWED_HOSTS") or ("github.com",),
        max_delete_fraction=_float("RAG_MAX_DELETE_FRACTION", 0.5),
    )
    validate(settings)
    return settings


def validate(settings: Settings) -> None:
    """Fail closed on unsafe or inconsistent configuration."""
    if settings.role not in ("api", "ingest"):
        raise RuntimeError("RAG_ROLE must be 'api' or 'ingest'")
    if settings.auth_mode not in AUTH_MODES:
        raise RuntimeError(f"AUTH_MODE must be one of {AUTH_MODES}")
    # Request authorization applies only to the API; the ingestion job serves no requests.
    if settings.role == "api" and settings.auth_mode == "local" and settings.running_in_azure:
        raise RuntimeError("AUTH_MODE=local is not allowed inside Azure Container Apps")
    if settings.role == "api" and settings.auth_mode == "easyauth" and not settings.allowed_principal_ids:
        raise RuntimeError("AUTH_MODE=easyauth requires ALLOWED_PRINCIPAL_IDS")
    if settings.source_kind not in SOURCE_KINDS:
        raise RuntimeError(f"RAG_SOURCE_KIND must be one of {SOURCE_KINDS}")
    if settings.reasoning_effort not in ("low", "medium", "high"):
        raise RuntimeError("RAG_REASONING_EFFORT must be low, medium, or high")
    if not 0.0 < settings.max_delete_fraction <= 1.0:
        raise RuntimeError("RAG_MAX_DELETE_FRACTION must be in (0, 1]")
    for endpoint in (settings.search_endpoint, settings.openai_endpoint):
        if not endpoint.startswith("https://"):
            raise RuntimeError("Service endpoints must use https://")
