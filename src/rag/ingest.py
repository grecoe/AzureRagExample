"""Ingestion: python -m rag.ingest seed|update [--dry-run]

seed    Re-embeds and uploads every file (first load or after a chunker change).
update  Re-embeds only files whose content hash changed, and removes deleted files.

Safety order: read the whole source, plan, upload and verify every new chunk, and only
then delete stale chunks. Any failure exits non-zero before deletion, so the index never
loses content because of a partial run. Re-running is safe and converges.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

from .answer import RagService
from .chunker import Chunk, chunk_markdown, embedding_text, file_hash
from .clients import async_credential, build_kernel, openai_client
from .config import Settings, load_settings
from .search_store import IndexedChunk, SearchStore
from .sources import SourceSnapshot, load_git, load_local
from .telemetry import configure_telemetry, flush_telemetry, track_event

log = logging.getLogger("rag.ingest")
EMBED_BATCH = 16


@dataclass
class Plan:
    upserts: dict[str, list[Chunk]] = field(default_factory=dict)  # path -> new chunks
    hashes: dict[str, str] = field(default_factory=dict)  # path -> new content hash
    deletes: list[str] = field(default_factory=list)  # chunk ids to remove after upload
    unchanged: int = 0
    removed_files: int = 0
    removed_chunks: int = 0  # net chunks lost: removed files plus files that now produce fewer chunks


def is_current(existing: list[IndexedChunk], new_hash: str) -> bool:
    """A file is current only if a complete chunk set carries the new hash."""
    if not existing:
        return False
    count = existing[0].chunk_count
    ordinals = sorted(c.chunk_ordinal for c in existing)
    return (
        ordinals == list(range(count))
        and all(c.chunk_count == count and c.content_hash == new_hash for c in existing)
    )


def build_plan(snapshot: SourceSnapshot, state: dict[str, list[IndexedChunk]], force: bool) -> Plan:
    plan = Plan()
    for path, text in sorted(snapshot.files.items()):
        new_hash = file_hash(text)
        existing = state.get(path, [])
        if not force and is_current(existing, new_hash):
            plan.unchanged += 1
            continue
        chunks = chunk_markdown(path, text)
        plan.upserts[path] = chunks
        plan.hashes[path] = new_hash
        new_ids = {c.chunk_id for c in chunks}
        plan.deletes.extend(c.id for c in existing if c.id not in new_ids)
        plan.removed_chunks += max(0, len(existing) - len(chunks))
    for path, existing in state.items():
        if path not in snapshot.files:
            plan.removed_files += 1
            plan.removed_chunks += len(existing)
            plan.deletes.extend(c.id for c in existing)
    return plan


def check_guards(snapshot: SourceSnapshot, state: dict[str, list[IndexedChunk]], plan: Plan,
                 max_delete_fraction: float) -> None:
    if not snapshot.files:
        raise RuntimeError("Source returned no files; refusing to continue")
    total = sum(len(v) for v in state.values())
    if total and plan.removed_chunks / total > max_delete_fraction:
        raise RuntimeError(
            f"Plan removes {plan.removed_chunks} of {total} chunks, above RAG_MAX_DELETE_FRACTION; "
            "confirm the source is correct, then raise the limit for one run"
        )


def to_document(chunk: Chunk, vector: list[float], content_hash: str, count: int, commit: str, now: str) -> dict:
    return {
        "id": chunk.chunk_id,
        "source_path": chunk.source_path,
        "locator": chunk.locator,
        "title": chunk.title,
        "content": chunk.content,
        "content_vector": vector,
        "content_hash": content_hash,
        "chunk_ordinal": chunk.ordinal,
        "chunk_count": count,
        "source_commit": commit,
        "ingested_at": now,
    }


def load_source(settings: Settings) -> SourceSnapshot:
    if settings.source_kind == "git":
        return load_git(settings.git_url, settings.git_ref, settings.git_include, settings.git_allowed_hosts)
    return load_local(settings.source_path, settings.git_include)


async def run(mode: str, dry_run: bool, stats: dict[str, int] | None = None) -> int:
    stats = {} if stats is None else stats
    settings = load_settings()
    configure_telemetry(settings)
    snapshot = load_source(settings)  # raises before any index change
    credential = async_credential(settings)
    try:
        async with SearchStore(settings, credential) as store:
            state = await store.list_state()
            plan = build_plan(snapshot, state, force=(mode == "seed"))
            check_guards(snapshot, state, plan, settings.max_delete_fraction)
            new_chunks = sum(len(c) for c in plan.upserts.values())
            stats.update(
                source_files=len(snapshot.files), changed_files=len(plan.upserts), unchanged_files=plan.unchanged,
                planned_chunks=new_chunks, planned_deletes=len(plan.deletes), removed_files=plan.removed_files,
            )
            log.info(
                "plan mode=%s files=%d changed=%d unchanged=%d chunks=%d deletes=%d removed_files=%d commit=%s",
                mode, len(snapshot.files), len(plan.upserts), plan.unchanged, new_chunks,
                len(plan.deletes), plan.removed_files, snapshot.commit[:12],
            )
            if dry_run:
                return 0

            client = openai_client(settings, credential)
            try:
                rag = RagService(settings, build_kernel(settings, client), store)
                now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
                for path, chunks in plan.upserts.items():
                    documents: list[dict] = []
                    for start in range(0, len(chunks), EMBED_BATCH):
                        batch = chunks[start : start + EMBED_BATCH]
                        vectors = await rag.embed([embedding_text(c) for c in batch])
                        documents.extend(
                            to_document(c, v, plan.hashes[path], len(chunks), snapshot.commit, now)
                            for c, v in zip(batch, vectors, strict=True)
                        )
                    await store.upload(documents)
                if plan.deletes:
                    await store.delete(plan.deletes)
            finally:
                await client.close()
            log.info("complete uploaded=%d deleted=%d", new_chunks, len(plan.deletes))
            stats.update(uploaded_chunks=new_chunks, deleted_chunks=len(plan.deletes))
            return 0
    finally:
        await credential.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="rag.ingest")
    parser.add_argument("mode", choices=["seed", "update"])
    parser.add_argument("--dry-run", action="store_true", help="Show the plan without embedding or writing")
    args = parser.parse_args(argv)
    stats: dict[str, int] = {}
    started = time.perf_counter()
    try:
        code = asyncio.run(run(args.mode, args.dry_run, stats))
        status, error_type = ("dry_run" if args.dry_run else "success"), ""
    except Exception as error:  # noqa: BLE001 - exit cleanly with a sanitized message
        logging.getLogger("rag.ingest").error("ingestion failed: %s", type(error).__name__)
        log.debug("details", exc_info=True)
        print(f"Ingestion failed: {error}" if isinstance(error, RuntimeError) else "Ingestion failed",
              file=sys.stderr)
        code, status, error_type = 1, "failed", type(error).__name__
    track_event(
        "RagIngestRun",
        status,
        measurements={"duration_ms": round((time.perf_counter() - started) * 1000, 1), **stats},
        mode=args.mode,
        dry_run=args.dry_run,
        error_type=error_type,
    )
    # The job exits right after this; export buffered telemetry first.
    flush_telemetry()
    return code


if __name__ == "__main__":
    sys.exit(main())
