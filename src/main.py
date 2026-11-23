"""Container entrypoint. RAG_ROLE selects the API (default) or the ingestion job."""

from __future__ import annotations

import os
import sys


def main() -> int:
    role = os.environ.get("RAG_ROLE", "api").strip().lower()
    if role == "ingest":
        from rag.ingest import main as ingest_main

        return ingest_main([os.environ.get("RAG_INGEST_MODE", "update")])
    if role != "api":
        print("RAG_ROLE must be 'api' or 'ingest'", file=sys.stderr)
        return 2

    import uvicorn

    from rag.app import create_app

    app = create_app()
    in_azure = bool(os.environ.get("CONTAINER_APP_NAME"))
    # Locally the API is reachable from this machine only.
    host = "0.0.0.0" if in_azure else "127.0.0.1"  # noqa: S104 - container ingress is the boundary
    uvicorn.run(app, host=host, port=int(os.environ.get("PORT", "8080")), proxy_headers=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
