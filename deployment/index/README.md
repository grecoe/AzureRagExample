# Search Index Definition

[rag-docs.index.json](rag-docs.index.json) is the index schema in the Azure AI Search REST format (API version `2025-09-01`). The `postprovision` hook replaces `name` and the `content_vector` dimensions with the azd values before sending it.

| Field | Type | Used for |
| --- | --- | --- |
| `id` | String, key | `sha256(path)` prefix plus the chunk position; stable across runs |
| `source_path` | String, filterable | The file the chunk came from |
| `locator` | String | Path plus heading anchor, shown as the citation |
| `title` | String, searchable (`en.microsoft`) | Heading trail, such as `Troubleshooting > Missing data` |
| `content` | String, searchable (`en.microsoft`) | The chunk text |
| `content_vector` | 3,072 × Single, HNSW cosine, `stored: false` | Vector search. It is not returned, which saves storage. |
| `content_hash` | String | SHA-256 of the normalized file and the chunker version; drives incremental updates |
| `chunk_ordinal`, `chunk_count` | Int32 | Detect incomplete files after a failed run |
| `source_commit` | String | Git commit or `local` |
| `ingested_at` | DateTimeOffset, sortable | Freshness checks |

**Vector search.** HNSW with `m` 4, `efConstruction` 400, `efSearch` 500, cosine metric. These are the service defaults and work well at this scale.

**Semantic configuration.** `default` uses `title` as the title field and `content` as the content field. The API requests it by name.

## Changing the Schema

| Change | In place? |
| --- | --- |
| Add a new field | Yes: edit the JSON, then `azd provision` or run the hook |
| Change a field's type, analyzer or vector dimensions; remove a field | No: use a blue/green rebuild with a new `RAG_INDEX_NAME` ([REPORT.md](../../REPORT.md#stage-9-rebuild-bluegreen)) |
