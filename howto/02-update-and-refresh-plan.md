# Update the Index and Plan Refreshes

The index should follow the source repository closely enough that answers are not stale, without spending money re-embedding unchanged text.

## How an Update Works

`update` mode compares every source file with what the index holds:

| File state | Action | Embedding cost |
| --- | --- | --- |
| Unchanged (same hash, complete chunk set) | Skipped | None |
| New or edited | Re-chunked, re-embedded, uploaded; leftover chunks deleted | That file only |
| Deleted from the source, or now skipped (too large, not UTF-8) | All its chunks deleted after uploads finish | None |
| Partly uploaded by a failed run | Treated as changed and repaired | That file only |

Two guards stop a run **before** any change:

- The source returned no files, which usually means a wrong URL, ref or include pattern.
- The plan would lose more than `RAG_MAX_DELETE_FRACTION` (50%) of indexed chunks, counting removed files and files that now yield fewer chunks.

## Refresh Plan

| Trigger | What to do | Mode | Who |
| --- | --- | --- | --- |
| Routine edits in the source repository | Daily schedule at 06:00 UTC (`ENABLE_INGEST_SCHEDULE=true`, `ingestCron` in Bicep) | `update` | Automatic |
| Urgent fix or a large merge | Start the job now: `az containerapp job start -n <job> -g <rg>` | `update` | Operator |
| Chunking or embedding-text logic changed | Increase `CHUNKER_VERSION` in `src/rag/chunker.py`, deploy, start the job | `update` (every file now differs) | Operator |
| Embedding model or dimensions changed | [Blue/green rebuild](#blue-green-rebuild) | `seed` into a new index | Operator |
| Index field type or analyzer changed | [Blue/green rebuild](#blue-green-rebuild) | `seed` into a new index | Operator |
| A field added | Edit `deployment/index/rag-docs.index.json`, run `pwsh ./scripts/create-search-index.ps1`, then `seed` to fill it | `seed` | Operator |
| Delete guard tripped | Confirm the source is right; set `RAG_MAX_DELETE_FRACTION` higher for one local run | `update` | Operator |
| Source moved (new URL or branch) | `azd env set RAG_GIT_URL …` / `RAG_GIT_REF …`, `azd provision`, dry-run locally first | `update` | Operator |

**Choosing the cadence.** Daily suits documentation that changes a few times a week; each run costs almost nothing when little changed. Use hourly (`0 * * * *`) only if answers must reflect edits within the hour. For near-real-time freshness, have a Git push webhook call Event Grid or Logic Apps, which starts the job; that is not built here.

**Overlapping runs.** Parallelism 1 limits a single execution, but a manual start during a scheduled run creates a second execution. Both write the same IDs, so the result is still correct; at worst, an older snapshot lands last and the next run corrects it. Avoid manual starts near 06:00 UTC.

## Change the Schedule

```powershell
cd deployment
azd env set ENABLE_INGEST_SCHEDULE true    # or false to stop scheduled runs
azd provision
```

To change the time, edit the `ingestCron` default in `deployment/infra/main.bicep` (UTC, five fields) or map it in `main.parameters.json`.

## Blue-Green Rebuild

Use this when the index must be recreated: a new embedding model or dimensions, or a changed field type. The live index keeps serving until the new one is ready.

1. **Create the new index** from `deployment/`. Process variables override azd values:

   ```powershell
   $env:AZURE_SEARCH_INDEX = 'rag-docs-v2'
   $env:AZURE_OPENAI_EMBEDDING_DIMENSIONS = '3072'   # the new dimension count
   pwsh ./scripts/create-search-index.ps1
   ```

2. **Seed it locally** from `src/`, with the same two variables set:

   ```powershell
   python -m rag.ingest seed
   ```

3. **Verify** by running the API locally against `rag-docs-v2` and asking known questions ([03-query.md](03-query.md)).
4. **Switch** from `deployment/`:

   ```powershell
   Remove-Item env:AZURE_SEARCH_INDEX, env:AZURE_OPENAI_EMBEDDING_DIMENSIONS
   azd env set RAG_INDEX_NAME rag-docs-v2
   azd provision
   ```

5. **Retire** the old index after a few days:

   ```powershell
   az rest --method delete --resource https://search.azure.com `
       --url "$(azd env get-value AZURE_SEARCH_ENDPOINT)/indexes/rag-docs?api-version=2025-09-01"
   ```

To roll back before step 5, set `RAG_INDEX_NAME` back and run `azd provision`.

**Embedding model changes.** The Bicep deploys one embedding model. To seed with a new model before switching, first add a second embedding deployment in `deployment/infra/modules/ai.bicep` and point step 2 at it with `AZURE_OPENAI_EMBEDDING_DEPLOYMENT`. Otherwise, changing the model parameters makes the API embed questions with the new model against the old index until step 4, which returns wrong results or errors.
