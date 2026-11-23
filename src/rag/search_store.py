"""Azure AI Search data-plane access: hybrid + semantic query, and verified writes.

The index schema is created by deployment/scripts/create-search-index.ps1 with the
operator's identity. Workload identities only hold data-plane roles, so this module
never creates or reads index definitions.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass

from azure.search.documents.aio import SearchClient
from azure.search.documents.models import VectorizedQuery

from .config import Settings

log = logging.getLogger("rag.search")

STATE_FIELDS = ["id", "source_path", "content_hash", "chunk_ordinal", "chunk_count"]
RESULT_FIELDS = ["id", "title", "content", "locator", "source_path"]
MAX_STATE_ROWS = 100_000  # Search skip limit; larger corpora need a different state store.
UPLOAD_BATCH = 50
RETRYABLE_STATUS = {409, 422, 429, 503}


@dataclass(frozen=True)
class IndexedChunk:
    id: str
    content_hash: str
    chunk_ordinal: int
    chunk_count: int


@dataclass(frozen=True)
class SearchHit:
    id: str
    title: str
    content: str
    locator: str
    score: float
    reranker_score: float | None


class SearchStore:
    def __init__(self, settings: Settings, credential) -> None:
        self._settings = settings
        self._client = SearchClient(settings.search_endpoint, settings.search_index, credential)

    async def __aenter__(self) -> "SearchStore":
        return self

    async def __aexit__(self, *exc) -> None:
        await self._client.close()

    async def query(self, text: str, vector: list[float], top: int) -> list[SearchHit]:
        """Hybrid (keyword + vector) retrieval re-ranked by the semantic ranker."""
        results = await self._client.search(
            search_text=text,
            vector_queries=[VectorizedQuery(vector=vector, k_nearest_neighbors=50, fields="content_vector")],
            query_type="semantic",
            semantic_configuration_name="default",
            select=RESULT_FIELDS,
            top=top,
        )
        hits: list[SearchHit] = []
        async for row in results:
            hits.append(
                SearchHit(
                    id=row["id"],
                    title=row.get("title") or "",
                    content=row.get("content") or "",
                    locator=row.get("locator") or row.get("source_path") or "",
                    score=float(row.get("@search.score") or 0.0),
                    reranker_score=row.get("@search.reranker_score"),
                )
            )
        return hits

    async def list_state(self) -> dict[str, list[IndexedChunk]]:
        """Current index contents grouped by source path. This is the ingestion state."""
        results = await self._client.search(search_text="*", select=STATE_FIELDS, top=MAX_STATE_ROWS)
        state: dict[str, list[IndexedChunk]] = {}
        count = 0
        async for row in results:
            count += 1
            state.setdefault(row["source_path"], []).append(
                IndexedChunk(row["id"], row.get("content_hash") or "", int(row.get("chunk_ordinal") or 0),
                             int(row.get("chunk_count") or 0))
            )
        if count >= MAX_STATE_ROWS:
            raise RuntimeError("Index has too many chunks to read state; use a dedicated state store")
        return state

    async def upload(self, documents: list[dict]) -> None:
        """Upsert in batches. Raises unless every document is confirmed written."""
        for start in range(0, len(documents), UPLOAD_BATCH):
            await self._write(documents[start : start + UPLOAD_BATCH], delete=False)

    async def delete(self, ids: list[str]) -> None:
        for start in range(0, len(ids), UPLOAD_BATCH):
            await self._write([{"id": i} for i in ids[start : start + UPLOAD_BATCH]], delete=True)

    async def _write(self, batch: list[dict], delete: bool) -> None:
        pending = batch
        for attempt in range(4):
            if delete:
                results = await self._client.delete_documents(documents=pending)
            else:
                results = await self._client.merge_or_upload_documents(documents=pending)
            failed_keys = {r.key for r in results if not r.succeeded}
            if not failed_keys:
                return
            fatal = [r for r in results if not r.succeeded and r.status_code not in RETRYABLE_STATUS]
            if fatal:
                raise RuntimeError(f"{len(fatal)} documents failed with non-retryable status codes")
            pending = [d for d in pending if d["id"] in failed_keys]
            log.warning("Retrying %d documents (attempt %d)", len(pending), attempt + 1)
            await asyncio.sleep(2**attempt)
        raise RuntimeError(f"{len(pending)} documents still failed after retries")
