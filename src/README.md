# Source Code

One Python package, [rag/](rag/README.md), serves two roles from a single container image:

| `RAG_ROLE` | Runs as | Entry |
| --- | --- | --- |
| `api` (default) | Container App | [main.py](main.py) starts FastAPI with uvicorn on port 8080 |
| `ingest` | Container Apps Job | [main.py](main.py) calls `rag.ingest` with `RAG_INGEST_MODE` (`update` by default) |

| File | Purpose |
| --- | --- |
| [main.py](main.py) | Container entry point. Binds `0.0.0.0` in Azure, `127.0.0.1` locally. |
| [Dockerfile](Dockerfile) | `python:3.12-slim-bookworm`, non-root user `10001`, includes `sample-data`. Build context is the parent folder, filtered by [../.dockerignore](../.dockerignore). ACR Tasks builds it in Azure. |
| [requirements.txt](requirements.txt) | Pinned versions, tested together. These are dependencies of this sample only. |
| [client_example.py](client_example.py) | How an application calls the deployed API with an Entra token |
| [tests/](tests/README.md) | 23 unit tests; no Azure access needed |

## Run Locally

Locally, every call uses **your** Azure CLI sign-in. You already hold the data roles from provisioning.

```powershell
cd src
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
az login

# Read the deployed endpoints from azd (run from the deployment folder)
Push-Location ..\deployment
foreach ($name in 'AZURE_SEARCH_ENDPOINT','AZURE_SEARCH_INDEX','AZURE_OPENAI_ENDPOINT',
                  'AZURE_OPENAI_EMBEDDING_DEPLOYMENT','AZURE_OPENAI_CHAT_DEPLOYMENT',
                  'AZURE_OPENAI_EMBEDDING_DIMENSIONS') {
    Set-Item "env:$name" (azd env get-value $name)
}
Pop-Location
$env:AUTH_MODE = 'local'
$env:RAG_SOURCE_PATH = '..\sample-data'

python -m rag.ingest update --dry-run   # show the plan
python -m rag.ingest seed               # embed and upload everything
python main.py                          # API on http://127.0.0.1:8080, docs at /docs
```

## Configuration

`rag/config.py` reads everything from environment variables and refuses unsafe combinations at start-up.

| Variable | Default | Notes |
| --- | --- | --- |
| `AZURE_SEARCH_ENDPOINT`, `AZURE_SEARCH_INDEX` | required | Must be `https://` |
| `AZURE_OPENAI_ENDPOINT` | required | Must be `https://` |
| `AZURE_OPENAI_EMBEDDING_DEPLOYMENT`, `AZURE_OPENAI_CHAT_DEPLOYMENT` | required | Deployment names |
| `AZURE_OPENAI_EMBEDDING_DIMENSIONS` | `3072` | 256–3,072; must match the index |
| `AZURE_CLIENT_ID` | — | Set in Azure to select the user-assigned identity |
| `RAG_ROLE` | `api` | `api` or `ingest` |
| `AUTH_MODE` | `local` | `local` or `easyauth`. The API refuses `local` inside Azure. |
| `ALLOWED_PRINCIPAL_IDS` | — | Comma-separated object IDs; required for `easyauth` |
| `RAG_TOP_K` | `5` | Passages retrieved |
| `RAG_MIN_RERANKER_SCORE` | `1.5` | Refuse to answer below this semantic reranker score (0–4) |
| `RAG_MAX_QUESTION_CHARS` | `1000` | |
| `RAG_MAX_COMPLETION_TOKENS` | `4000` | Includes reasoning tokens |
| `RAG_REASONING_EFFORT` | `low` | |
| `RAG_MAX_CONCURRENT_ANSWERS` | `4` | Per replica |
| `RAG_SOURCE_KIND` | `local` | `local` or `git` |
| `RAG_SOURCE_PATH` | `sample-data` | For `local` |
| `RAG_GIT_URL`, `RAG_GIT_REF` | —, `main` | For `git`; `https` only |
| `RAG_GIT_INCLUDE` | `**/*.md` | Glob of files to index |
| `RAG_GIT_ALLOWED_HOSTS` | `github.com` | Comma-separated host allow-list |
| `RAG_MAX_DELETE_FRACTION` | `0.5` | Stop if a run would delete more than this share of chunks |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | — | Telemetry, sent with an Entra token |
