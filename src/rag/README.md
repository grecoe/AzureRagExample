# The `rag` Package

| Module | Responsibility |
| --- | --- |
| [config.py](config.py) | Load and validate settings from the environment |
| [clients.py](clients.py) | Credentials (managed identity in Azure, Azure CLI locally); the OpenAI client with Entra tokens; the Semantic Kernel with chat and embedding services |
| [sources.py](sources.py) | Read documents from a local folder or a shallow Git clone, with limits and safety checks |
| [chunker.py](chunker.py) | Split Markdown by heading into bounded chunks with stable IDs and content hashes |
| [search_store.py](search_store.py) | Azure AI Search: hybrid query, list index state, batched upload and delete with retries |
| [answer.py](answer.py) | Grounded answering through Semantic Kernel; the retrieval plugin |
| [ingest.py](ingest.py) | The `seed` / `update` command |
| [app.py](app.py) | FastAPI endpoints and the authorization check |
| [telemetry.py](telemetry.py) | Azure Monitor OpenTelemetry with Entra authentication; container identity and the `RagApiCall` / `RagIngestRun` custom events |

## Query Path (`answer.py`)

```text
question
  -> embed (text-embedding-3-large, 3,072 dimensions)
  -> hybrid search: keyword + vector + semantic reranker, top 5
  -> evidence gate: top reranker score >= 1.5, else "not_found"
  -> GPT-5.6 with SOURCES S1..S5, JSON output required
  -> validate: every sentence must cite a supplied label, else "not_found"
  -> answer + only the cited passages
```

Method-by-method details are in [../RagService.md](../RagService.md).

The prompt marks every source as untrusted data, and `render_sources` stops a document from closing its own `<source>` block. These steps reduce prompt-injection risk; they do not eliminate it.

The evidence gate and citation check are heuristics. They confirm that each sentence points to a retrieved passage. They do not prove that the passage supports the sentence. Treat every answer as a draft for a person to check against its citations.

## Ingestion Path (`ingest.py`)

```text
load whole source (fails before touching the index)
  -> list index state (id, path, hash, ordinal, count)
  -> plan: changed files, unchanged files, chunks to delete
  -> guards: source not empty; net chunks lost (removed files plus files that now yield fewer chunks) <= RAG_MAX_DELETE_FRACTION
  -> for each changed file: embed in batches of 16, upload in batches of 50
  -> delete stale chunks only after every upload succeeded
```

A file counts as current only when its complete chunk set carries the new hash. After a failed run, partly uploaded files are reprocessed next time, so another run fixes the index.

`file_hash` includes `CHUNKER_VERSION`. Increase that constant whenever chunking or embedding-text logic changes, so the next `update` re-embeds every file.

## Semantic Kernel Use

`clients.build_kernel` registers two services. Both share one `AsyncOpenAI` client pointed at the Foundry resource's OpenAI v1 endpoint (`<endpoint>/openai/v1/`). That client authenticates with a refreshing Entra token for `https://cognitiveservices.azure.com/.default`, never a key.

| Service ID | Semantic Kernel type | Deployment |
| --- | --- | --- |
| `chat` | `OpenAIChatCompletion` | `gpt-5.6-sol` |
| `embedding` | `OpenAITextEmbedding` | `text-embedding-3-large` |

`RetrievalPlugin.search_documents` is a kernel function. An agent built on the same kernel can call retrieval as a tool. See [../../howto/04-consume.md](../../howto/04-consume.md).
