"""Structure-aware Markdown chunking.

Pure functions with no Azure dependencies so they can be unit tested offline.
Chunks follow Markdown headings so each citation points at a meaningful section.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

# Bump when chunking behavior changes. It is part of every file hash, so a bump
# makes the next incremental update re-embed every file.
CHUNKER_VERSION = "1"

# About 750 tokens of English at ~4 characters per token: small enough to keep
# citations precise.
DEFAULT_MAX_CHARS = 3000
DEFAULT_OVERLAP_CHARS = 300

# Hard limit that guarantees the 8,192-token embedding input limit without a
# tokenizer: byte-level BPE tokens each cover at least one UTF-8 byte, so a
# 6,000-byte chunk plus a 600-byte title can never exceed 6,600 tokens.
MAX_CHUNK_BYTES = 6000
MAX_TITLE_CHARS = 150

_HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*#*\s*$")
_FENCE = re.compile(r"^\s*(```|~~~)")
_HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)


@dataclass(frozen=True)
class Chunk:
    source_path: str
    ordinal: int
    title: str
    anchor: str
    content: str

    @property
    def chunk_id(self) -> str:
        return make_chunk_id(self.source_path, self.ordinal)

    @property
    def locator(self) -> str:
        return f"{self.source_path}#{self.anchor}" if self.anchor else self.source_path


def make_chunk_id(source_path: str, ordinal: int) -> str:
    """Deterministic, Search-safe document key (letters, digits, dash only)."""
    digest = hashlib.sha256(source_path.encode("utf-8")).hexdigest()[:32]
    return f"{digest}-{ordinal:04d}"


def file_hash(text: str) -> str:
    """Hash of the normalized file text plus the chunker version."""
    normalized = normalize(text)
    return hashlib.sha256(f"{CHUNKER_VERSION}\n{normalized}".encode("utf-8")).hexdigest()


def normalize(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = _HTML_COMMENT.sub("", text)
    return text.strip() + "\n"


def slugify(heading: str) -> str:
    """GitHub-style anchor: lowercase, punctuation removed, spaces to dashes."""
    slug = heading.strip().lower()
    slug = re.sub(r"[^\w\- ]", "", slug)
    return re.sub(r"\s", "-", slug)


def _sections(text: str) -> list[tuple[list[str], str]]:
    """Split into (heading_path, body) pairs, ignoring headings inside code fences."""
    sections: list[tuple[list[str], str]] = []
    path: list[str] = []
    buffer: list[str] = []
    in_fence = False

    def flush() -> None:
        body = "\n".join(buffer).strip()
        if body:
            sections.append((list(path), body))
        buffer.clear()

    for line in text.split("\n"):
        if _FENCE.match(line):
            in_fence = not in_fence
            buffer.append(line)
            continue
        match = None if in_fence else _HEADING.match(line)
        if match:
            flush()
            level = len(match.group(1))
            path[:] = path[: level - 1]
            path.extend([""] * (level - 1 - len(path)))
            path.append(match.group(2).strip())
            buffer.append(line)
        else:
            buffer.append(line)
    flush()
    return sections


def _split_long(body: str, max_chars: int, overlap: int) -> list[str]:
    if len(body) <= max_chars:
        return [body]
    paragraphs = [p for p in body.split("\n\n") if p.strip()]
    pieces: list[str] = []
    current = ""
    for paragraph in paragraphs:
        while len(paragraph) > max_chars:
            # A single paragraph longer than the limit is hard-split.
            head, paragraph = paragraph[:max_chars], paragraph[max_chars - overlap :]
            if current:
                pieces.append(current)
                current = ""
            pieces.append(head)
        candidate = f"{current}\n\n{paragraph}" if current else paragraph
        if len(candidate) > max_chars and current:
            pieces.append(current)
            tail = current[-overlap:] if overlap else ""
            current = f"{tail}\n\n{paragraph}" if tail else paragraph
        else:
            current = candidate
    if current:
        pieces.append(current)
    return pieces


def _enforce_byte_limit(piece: str, max_bytes: int) -> list[str]:
    """Split on character boundaries until every part fits in max_bytes."""
    parts: list[str] = []
    while len(piece.encode("utf-8")) > max_bytes:
        cut = max_bytes
        while len(piece[:cut].encode("utf-8")) > max_bytes:
            cut -= 1
        parts.append(piece[:cut])
        piece = piece[cut:]
    if piece.strip():
        parts.append(piece)
    return parts


def chunk_markdown(
    source_path: str,
    text: str,
    max_chars: int = DEFAULT_MAX_CHARS,
    overlap_chars: int = DEFAULT_OVERLAP_CHARS,
    max_bytes: int = MAX_CHUNK_BYTES,
) -> list[Chunk]:
    """Chunk one Markdown file. Ordinals are stable for unchanged input."""
    if overlap_chars >= max_chars:
        raise ValueError("overlap_chars must be smaller than max_chars")
    chunks: list[Chunk] = []
    for heading_path, body in _sections(normalize(text)):
        names = [h for h in heading_path if h]
        title = (" > ".join(names) if names else source_path)[:MAX_TITLE_CHARS]
        anchor = slugify(names[-1]) if names else ""
        for piece in _split_long(body, max_chars, overlap_chars):
            for part in _enforce_byte_limit(piece, max_bytes):
                chunks.append(Chunk(source_path, len(chunks), title, anchor, part))
    return chunks


def embedding_text(chunk: Chunk) -> str:
    """Text sent to the embedding model. Bounded by MAX_TITLE_CHARS + MAX_CHUNK_BYTES."""
    return f"{chunk.title}\n\n{chunk.content}"
