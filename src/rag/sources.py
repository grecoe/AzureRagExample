"""Read the source corpus from a local folder or a public Git repository.

Everything read here is untrusted input. The code bounds size, refuses symbolic
links and path escapes, and never passes data through a shell.
"""

from __future__ import annotations

import fnmatch
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from urllib.parse import urlparse

MAX_FILES = 2000
MAX_FILE_BYTES = 1_000_000
MAX_TOTAL_BYTES = 50_000_000
GIT_TIMEOUT_SECONDS = 300
_SAFE_REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$")
_SAFE_PATH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/ -]{0,299}$")


class SourceError(RuntimeError):
    """Raised for any source problem. Messages never include remote output."""


@dataclass(frozen=True)
class SourceSnapshot:
    files: dict[str, str]  # relative POSIX path -> text
    commit: str  # Git commit SHA, or "local"


def validate_git_url(url: str, allowed_hosts: tuple[str, ...]) -> str:
    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise SourceError("Git URL must use https")
    if parsed.username or parsed.password or "@" in parsed.netloc:
        raise SourceError("Git URL must not contain credentials")
    if parsed.query or parsed.fragment:
        raise SourceError("Git URL must not contain a query or fragment")
    host = (parsed.hostname or "").lower()
    if host not in allowed_hosts:
        raise SourceError(f"Git host '{host}' is not in RAG_GIT_ALLOWED_HOSTS")
    return url


def validate_ref(ref: str) -> str:
    if not _SAFE_REF.match(ref) or ".." in ref:
        raise SourceError("Git ref contains unsupported characters")
    return ref


def static_prefix(pattern: str) -> str:
    """Directory part of a glob before its first wildcard, used for sparse checkout."""
    parts: list[str] = []
    for part in PurePosixPath(pattern).parts[:-1]:
        if any(ch in part for ch in "*?["):
            break
        parts.append(part)
    return "/".join(parts)


def _matches(relative: str, pattern: str) -> bool:
    if fnmatch.fnmatch(relative, pattern):
        return True
    # Let "**/" also match zero directories, as most users expect.
    return "**/" in pattern and fnmatch.fnmatch(relative, pattern.replace("**/", ""))


def collect_files(root: Path, include: str) -> dict[str, str]:
    """Read matching UTF-8 files under root with size, symlink, and containment checks."""
    root = root.resolve()
    files: dict[str, str] = {}
    total = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d != ".git" and not (Path(dirpath) / d).is_symlink())
        for name in sorted(filenames):
            path = Path(dirpath) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink() or not _matches(relative, include):
                continue
            if not _SAFE_PATH.match(relative) or not path.resolve().is_relative_to(root):
                continue
            size = path.stat().st_size
            if size > MAX_FILE_BYTES:
                continue
            total += size
            if len(files) >= MAX_FILES or total > MAX_TOTAL_BYTES:
                raise SourceError("Source exceeds the file-count or size limit")
            try:
                files[relative] = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
    return files


def _git(args: list[str], cwd: Path | None = None) -> str:
    env = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": tempfile.gettempdir(),
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
    }
    if os.name == "nt" and os.environ.get("SYSTEMROOT"):
        env["SYSTEMROOT"] = os.environ["SYSTEMROOT"]  # required by git on Windows workstations
    # No redirects: a redirect could move the clone to a host outside RAG_GIT_ALLOWED_HOSTS.
    hardening = ["-c", "core.symlinks=false", "-c", "protocol.allow=never", "-c", "protocol.https.allow=always",
                 "-c", "http.followRedirects=false"]
    try:
        result = subprocess.run(
            ["git", *hardening, *args],
            cwd=cwd,
            env=env,
            capture_output=True,
            text=True,
            timeout=GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise SourceError("git timed out") from exc
    if result.returncode != 0:
        # Remote output is untrusted and may be large; report only the subcommand and exit code.
        raise SourceError(f"git {args[0]} failed with exit code {result.returncode}")
    return result.stdout.strip()


def load_git(url: str, ref: str, include: str, allowed_hosts: tuple[str, ...]) -> SourceSnapshot:
    validate_git_url(url, allowed_hosts)
    validate_ref(ref)
    with tempfile.TemporaryDirectory(prefix="rag-src-") as tmp:
        repo = Path(tmp) / "repo"
        _git(["clone", "--depth", "1", "--filter=blob:none", "--sparse", "--single-branch",
              "--branch", ref, "--", url, str(repo)])
        prefix = static_prefix(include)
        if prefix:
            _git(["sparse-checkout", "set", "--", prefix], cwd=repo)
        else:
            _git(["sparse-checkout", "disable"], cwd=repo)
        commit = _git(["rev-parse", "HEAD"], cwd=repo)
        files = collect_files(repo, include)
    return SourceSnapshot(files=files, commit=commit)


def load_local(path: str, include: str = "**/*.md") -> SourceSnapshot:
    root = Path(path)
    if not root.is_dir():
        raise SourceError(f"Local source folder not found: {path}")
    return SourceSnapshot(files=collect_files(root, include), commit="local")
