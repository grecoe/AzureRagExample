# RagService Reference

`RagService` in [rag/answer.py](rag/answer.py) is the single entry point for answering and searching. The API endpoints, the ingestion job and Semantic Kernel agents all call it.

| Method | Called by | Returns | Uses the language model |
| --- | --- | --- | --- |
| [`ask(question, extractive=False)`](#askquestion-extractivefalse) | `POST /ask` | `Answer` | Yes, unless `extractive=True` or the evidence is weak |
| [`retrieve(query)`](#retrievequery) | `POST /search`, `ask`, `retrieval.search_documents` | `list[SearchHit]` | No (embeddings only) |
| [`embed(texts)`](#embedtexts) | `retrieve`, the ingestion job | `list[list[float]]` | No (embeddings only) |

## How the Pieces Fit

Semantic Kernel supplies the two model services, chat and embedding, which `clients.build_kernel` registers. `RagService` runs the steps in a fixed order. The language model never decides whether to search. That guarantees every answer is searched, scored against a threshold and citation-checked before it is returned.

```text
POST /ask    -> ask()      -> retrieve() -> embed() -> SearchStore.query() -> evidence gate -> chat model -> citation check
POST /search -> retrieve() -> embed() -> SearchStore.query()
agent tool   -> retrieval.search_documents -> retrieve() -> passages as <source> blocks
```

Search goes straight to Azure AI Search through the `azure-search-documents` SDK, not through a Semantic Kernel vector store connector. The query asks for the semantic reranker score, which the evidence gate needs.

## Construction

```python
RagService(settings: Settings, kernel: Kernel, store: SearchStore)
```

| Argument | Source |
| --- | --- |
| `settings` | `config.load_settings()`, read from environment variables |
| `kernel` | `clients.build_kernel(settings, openai_client(settings, credential))`, with services `chat` and `embedding` |
| `store` | `SearchStore(settings, credential)`, an async Azure AI Search client |

The constructor registers `RetrievalPlugin` on the kernel as `retrieval`. The API builds one instance at start-up in `app.lifespan`. Pattern C in [../howto/04-consume.md](../howto/04-consume.md#pattern-c-python-package-and-semantic-kernel) builds one in your own code.

Every call authenticates with Microsoft Entra ID: the managed identity in Azure, or your Azure CLI sign-in locally. No keys are used.

## `ask(question, extractive=False)`

Answers a question from the indexed documents, or refuses.

| Step | What happens | Setting |
| --- | --- | --- |
| 1. Retrieve | Calls `retrieve(question)` and labels the hits `S1`, `S2`, and so on | `RAG_TOP_K` (5) |
| 2. Evidence gate | If there are no hits, or the top hit's reranker score is missing or below the threshold, returns `not_found` | `RAG_MIN_RERANKER_SCORE` (1.5, on a 0–4 scale) |
| 3. Extractive exit | If `extractive=True`, returns the passages without calling the language model | — |
| 4. Generate | Sends `SYSTEM_PROMPT` and the passages, wrapped as `<source>` blocks, to the `chat` service and requires a JSON reply | `RAG_MAX_COMPLETION_TOKENS` (4,000), `RAG_REASONING_EFFORT` (`low`) |
| 5. Validate | `validate_model_output` accepts the reply only if it is valid JSON and every sentence cites at least one supplied label | — |
| 6. Return | `answered`, with only the passages that were cited | — |

The prompt tells the model to treat the sources as untrusted data, to use no outside knowledge, and to cite every sentence. `render_sources` escapes `</source` inside a document, so the document cannot close its own block and pose as instructions.

**Returns** an `Answer`. `POST /ask` serializes it with `to_dict()`.

| Field | `answered` | `not_found` | `extractive` |
| --- | --- | --- | --- |
| `status` | `"answered"` | `"not_found"` | `"extractive"` |
| `answer` | Sentences joined, each followed by its labels, for example `... [S1, S2]` | `"I could not find this in the indexed documents."` | `""` |
| `sentences` | `[{"text": "...", "citations": ["S1"]}]` | `[]` | `[]` |
| `passages` | Only the cited passages | All retrieved passages, for display as "possibly related" | All retrieved passages |

Each passage has `label`, `id`, `title`, `locator` and `content`. Build source links from `locator`.

`ask` returns `not_found` for three reasons, which appear in the `rag.answer` log as `reason=`:

| Reason | Meaning |
| --- | --- |
| `weak_evidence` | The top reranker score was below the threshold or missing |
| `model_not_found` | The model replied `{"not_found": true}` |
| `invalid_citations` | The reply was not valid JSON, had an empty sentence, or cited a label it was not given |

Extractive mode still applies the evidence gate. A weak match returns `not_found`, not passages.

**Errors.** Failures from Azure AI Search or Azure OpenAI raise an exception. The API turns them into HTTP 502 without the upstream error text. The OpenAI client retries three times and times out after 60 seconds.

```python
answer = await rag.ask("How long is raw telemetry kept?")
if answer.status == "answered":
    print(answer.answer)
    for p in answer.passages:
        print(p["label"], p["locator"])
```

## `retrieve(query)`

Finds the most relevant passages for a query, without applying a threshold and without generating an answer.

1. Calls `embed([query])` for a 3,072-dimension vector.
2. Calls `SearchStore.query`, which runs one hybrid query against Azure AI Search:
   - keyword search on the query text;
   - vector search on `content_vector`, using the 50 nearest neighbors;
   - semantic reranking with the `default` semantic configuration;
   - the top `RAG_TOP_K` results, with the fields `id`, `title`, `content`, `locator` and `source_path`.

**Returns** a list of `SearchHit` objects in reranked order.

| Field | Meaning |
| --- | --- |
| `id` | Chunk ID |
| `title` | Heading path of the chunk, such as `Troubleshooting Fleet Telemetry > Batches are rejected with HTTP 401`, or the file path when there are no headings |
| `content` | Chunk text |
| `locator` | File path plus heading anchor, such as `troubleshooting.md#batches-are-rejected-with-http-401`, or just the file path |
| `score` | Hybrid search score |
| `reranker_score` | Semantic reranker score (0–4), or `None` |

`POST /search` converts the hits with `to_passages` and returns `{"passages": [...]}`, with each passage labeled `S1`, `S2`, and so on. Scores are not included in the response. To view scores, query the index directly as shown in [../howto/03-query.md](../howto/03-query.md#tuning-relevance).

Because `retrieve` applies no threshold, `/search` returns the closest matches even when none are relevant. It returns an empty list only when the index has no matches.

```python
hits = await rag.retrieve("certificate expired")
for h in hits:
    print(round(h.reranker_score or 0, 2), h.title, h.locator)
```

## `embed(texts)`

Turns text into vectors with the `embedding` service (`text-embedding-3-large`).

- Requests `AZURE_OPENAI_EMBEDDING_DIMENSIONS` dimensions (3,072 by default), which must match the index.
- Raises `RuntimeError("Embedding dimensions do not match the index")` if any vector has a different length.
- Accepts a batch. The ingestion job sends 16 chunks per call.

**Returns** one list of floats per input, in the same order.

```python
vectors = await rag.embed(["How long is raw telemetry kept?"])
```

## `retrieval.search_documents` (Semantic Kernel Tool)

`RetrievalPlugin` exposes `retrieve` to Semantic Kernel agents as the kernel function `retrieval.search_documents(query: str) -> str`. It returns the passages as fenced `<source label="S1" title="...">` blocks, the same format `ask` sends to the model.

With automatic function calling (`FunctionChoiceBehavior.Auto()`), the agent's model decides when to search. That path skips the evidence gate and the citation check, so the agent's own prompt must treat sources as untrusted and require citations, as `SYSTEM_PROMPT` does. Use `ask` when you need those guarantees.

## Settings That Affect RagService

| Variable | Default | Affects |
| --- | --- | --- |
| `RAG_TOP_K` | `5` | Passages returned by `retrieve` and sent by `ask` |
| `RAG_MIN_RERANKER_SCORE` | `1.5` | The evidence gate in `ask` |
| `RAG_MAX_COMPLETION_TOKENS` | `4000` | Output limit for `ask`, including reasoning tokens |
| `RAG_REASONING_EFFORT` | `low` | Model reasoning effort in `ask` |
| `AZURE_OPENAI_EMBEDDING_DIMENSIONS` | `3072` | `embed`; must match the index |
| `AZURE_OPENAI_CHAT_DEPLOYMENT`, `AZURE_OPENAI_EMBEDDING_DEPLOYMENT` | required | The models behind the `chat` and `embedding` services |

Question length (`RAG_MAX_QUESTION_CHARS`) and concurrency (`RAG_MAX_CONCURRENT_ANSWERS`) are enforced by the API in `app.py`, not by `RagService`. Code that calls `RagService` directly must apply its own limits. All settings are listed in [README.md](README.md#configuration).
