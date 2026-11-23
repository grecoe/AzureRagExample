# Seed the Index

After `azd up`, the index exists but is empty. Seed it once, check the result, and only then turn on scheduled refreshes.

## Choose a Source

| Source | Set | Good for |
| --- | --- | --- |
| Sample data (default) | Nothing: `RAG_SOURCE_KIND=local` indexes `sample-data/`, which is baked into the image | A first end-to-end check |
| A public Git repository | `RAG_SOURCE_KIND=git`, `RAG_GIT_URL`, optionally `RAG_GIT_REF`, `RAG_GIT_INCLUDE`, `RAG_GIT_ALLOWED_HOSTS` | Your real documentation |

The job clones Git repositories anonymously over HTTPS, so **only public repositories work** as delivered. A private repository needs a credential; see [Boundaries](#boundaries).

To switch to a Git source:

```powershell
cd deployment
azd env set RAG_SOURCE_KIND git
azd env set RAG_GIT_URL https://github.com/<owner>/<repo>.git
azd env set RAG_GIT_REF main
azd env set RAG_GIT_INCLUDE 'docs/**/*.md'
azd provision
```

Use a branch or tag you trust. Everything in those files becomes text the model reads, so a hostile document can try to steer answers (prompt injection). The system prompt and source fencing reduce this risk but cannot remove it.

## Preview First

From your workstation, show what would happen without changing anything (environment set-up is in [../src/README.md](../src/README.md#run-locally)):

```powershell
cd src
python -m rag.ingest update --dry-run
```

The log line `plan mode=update files=… changed=… chunks=… deletes=…` shows the work. On an empty index, every file appears as changed and there are no deletes.

## Option A: Seed with the Job (Recommended)

The job runs inside Azure with its managed identity, which can write to the index.

```powershell
cd deployment
$rg  = azd env get-value AZURE_RESOURCE_GROUP
$job = azd env get-value INGEST_JOB_NAME
az containerapp job start --name $job --resource-group $rg
az containerapp job execution list --name $job --resource-group $rg `
    --query "[].{name:name, status:properties.status, start:properties.startTime}" -o table
```

The job runs in `update` mode, which indexes everything when the index is empty. Wait for `Succeeded`.

## Option B: Seed from Your Workstation

Use this when you want to watch progress or force a full re-embed (`seed` mode). Your account has Search Index Data Contributor and Cognitive Services OpenAI User.

```powershell
cd src
python -m rag.ingest seed
```

For a Git source locally, set `RAG_SOURCE_KIND=git` and `RAG_GIT_URL` in your session. `git` must be installed.

## Check the Result

Count the documents (chunks) in the index:

```powershell
cd deployment
$endpoint = azd env get-value AZURE_SEARCH_ENDPOINT
$index    = azd env get-value AZURE_SEARCH_INDEX
az rest --method get --resource https://search.azure.com `
    --url "$endpoint/indexes/$index/docs/`$count?api-version=2025-09-01"
```

Then ask a question whose answer you know ([03-query.md](03-query.md)). For the sample data, try "How often do devices send telemetry?".

## Then Turn On the Schedule

```powershell
azd env set ENABLE_INGEST_SCHEDULE true
azd provision
```

See [02-update-and-refresh-plan.md](02-update-and-refresh-plan.md).

## Limits

| Limit | Value | Set in |
| --- | --- | --- |
| Files per run | 2,000 (the run stops before changing the index) | `sources.py` `MAX_FILES` |
| Size per file | 1 MB. Larger files, and files that are not UTF-8, are skipped. Chunks already indexed from them are removed. | `MAX_FILE_BYTES` |
| Total size per run | 50 MB (the run stops before changing the index) | `MAX_TOTAL_BYTES` |
| Chunks the index can track | 100,000 | `search_store.py` `MAX_STATE_ROWS` (the Search `$skip` limit) |
| Job run time | 1 hour | `ingest-job.bicep` `replicaTimeout` |

## Boundaries

- **Private repositories** need a token. The secure way is a read-only token in Azure Key Vault, referenced by the job as a Key Vault secret through its managed identity. That is not built here.
- **Other formats** (PDF, Word) need a document-cracking step such as Azure AI Document Intelligence.
- **More than 100,000 chunks** need a different state store or a partitioned listing.
