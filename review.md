# Design Review

An independent reviewer (a rubber-duck agent) challenged the design before any code was written. Every High finding changed the design. This file records what was found and what was done. The security-focused review is in [SECURITY-REVIEW.md](SECURITY-REVIEW.md).

## Findings and Resolutions

| # | Severity | Finding | Resolution | Where |
| --- | --- | --- | --- | --- |
| 1 | High | Internal-only ingress is not authorization; anything in the environment could call the API. | Two modes. **Locked** (default): no ingress at all. **Easy Auth**: external HTTPS with Entra ID tokens, the operator as the only allowed principal, and the Azure CLI as the only allowed client. The app checks the principal again. | `modules/api.bicep`, `src/rag/app.py` |
| 2 | High | Easy Auth needs an app registration with a defined audience, and nothing stops other users in the tenant from getting a token. | Optional script creates a single-tenant registration with no secret, v2 tokens, one scope, the Azure CLI pre-authorized, and **assignment required** with only the signed-in user assigned. | `scripts/create-api-app-registration.ps1` |
| 3 | High | Using the index as the state store can leave partial files and delete good data. | Each chunk stores `chunk_ordinal` and `chunk_count`. A file is current only if every ordinal is present with the new hash. New chunks upload before stale ones are deleted. Every upload result is checked and retried; any failure stops the run before deletes. | `src/rag/ingest.py`, `src/rag/search_store.py` |
| 4 | High | A broken source (empty clone, wrong path) could wipe the index. | The source loads before the index is touched. The run stops if the source is empty or if it would delete more than `RAG_MAX_DELETE_FRACTION` (50%) of chunks. | `src/rag/ingest.py` |
| 5 | High | "Grounded" answers were unenforced; the model could answer from general knowledge. | Relevance gate on the top reranker score (missing score means refuse). The model returns JSON in which every sentence cites supplied labels; otherwise the result is `not_found` with the passages. Sources are fenced as untrusted data. `extractive` mode skips the model. The gate is a heuristic, consistent with ADR-0039 (a score is evidence, not a decision). | `src/rag/answer.py` |
| 6 | Medium | Custom deployment scripts for the job would drift from azd. | Native azd support: two `containerapp` services building one image, with the azd pattern that keeps the deployed image on re-provision. | `deployment/azure.yaml`, `infra/main.bicep` |
| 7 | Medium | A daily schedule running before the first seed is verified would repeat any mistake. | The job is manual until `ENABLE_INGEST_SCHEDULE=true`. | `modules/ingest-job.bicep` |
| 8 | Medium | Giving the ingest identity Search Service Contributor (to create the index) is more than it needs. | The operator creates the index in the `postprovision` hook. Workloads hold data-plane roles only. | `scripts/create-search-index.ps1`, `modules/roles.bicep` |
| 9 | Medium | A copied or stale `AZURE_PRINCIPAL_ID`, or azd deploying as a different identity, could grant access to the wrong person. | azd resolves the principal itself; nothing is stored. The `preprovision` hook requires `auth.useAzCliAuth`, a user sign-in in the expected tenant and subscription, a matching principal if one is present, and no other people with roles in the resource group. `principalType` allows only `User`. | `scripts/check-identity.ps1`, `infra/main.bicep` |
| 10 | Medium | GPT-5 family models reject `temperature` and count reasoning tokens against the output limit. | No `temperature`; `max_completion_tokens` 4,000; `reasoning_effort` `low` by default. | `src/rag/answer.py`, `src/rag/config.py` |
| 11 | Medium | Large chunks could exceed the embedding model's 8,192-token input. | Chunks are capped at 6,000 bytes and titles at 150 characters. A token is at least one byte, so input stays under the limit. Batches of 16 stay far under the request limit. | `src/rag/chunker.py`, `src/rag/ingest.py` |
| 12 | Medium | Telemetry with a connection-string key, or logging question text, would weaken the keyless and privacy goals. | Application Insights has local auth disabled; export uses the managed identity. Logs record counts and outcomes only. | `src/rag/telemetry.py`, `modules/monitoring.bicep` |
| 13 | Medium | Git sources can carry credentials in URLs, symlinks and huge repositories. | HTTPS only, host allow-list, no credentials, query or fragment; shallow, sparse clone; symlinks off; file, size and count limits; git errors are not echoed. | `src/rag/sources.py` |

## Confirmed by the Reviewer

- Search Index Data Reader is enough for hybrid and semantic queries, provided the API never reads the schema.
- A sync managed-identity credential works for the Azure Monitor exporter.
- Public endpoints are acceptable for a sample over public data, with keyless RBAC everywhere.

## Corrections Found While Writing the Documentation

| Issue | Fix |
| --- | --- |
| Blue/green steps changed the azd index name before the new index existed, which would break queries | Create and seed the new index first, then switch `RAG_INDEX_NAME` and provision, then retire the old one |
| Docs claimed a chunker change would not re-embed files | `CHUNKER_VERSION` is part of the file hash; increasing it re-embeds everything on the next `update` |
| Git source settings could not be set from azd | Mapped `RAG_SOURCE_KIND`, `RAG_GIT_*` in `main.parameters.json` |
| Docs named Azure-specific Semantic Kernel classes | The code uses `OpenAIChatCompletion` and `OpenAITextEmbedding` on the `/openai/v1/` endpoint |
| Upload retries described as "4 retries" | 4 attempts in total, with exponential backoff |

## Accepted Limits

- Citation checks prove a sentence names a supplied passage, not that the passage supports it.
- Changing the embedding model in place breaks queries until the new index is live; a second embedding deployment avoids this.
- The reranker threshold of 1.5 is a starting point and needs tuning with real questions.
