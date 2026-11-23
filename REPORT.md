# RAG Example: All-Up Report

**Outcome:** a complete RAG system is designed, written and validated locally, deployed with one `azd up` into resource group `<resource-group>`, seeded, and answering cited questions (see [Deployment Status](#deployment-status)). Every service-to-service call uses a managed identity, and the only human with access is the operator who deploys it.

**Validated locally:**

- 23 offline unit tests pass.
- An offline smoke test of the answer path passed.
- `az bicep build` reports no warnings.
- All PowerShell scripts parse.
- The JSON and YAML files parse.

**Not yet validated:** a real deployment, model quota and tenant policies. See [Open Assumptions](#open-assumptions).

## Deployment Status

Deployed on 2026-11-23 to subscription `<subscription-id>`, resource group `<resource-group>`, azd environment `rag-poc`.

| Resource | Name | Region |
| --- | --- | --- |
| Container Apps environment (VNet-injected) | `cae-<suffix>` | eastus2 |
| API Container App (no ingress) | `ca-api-<suffix>` | eastus2 |
| Ingestion job | `caj-ingest-<suffix>` | eastus2 |
| Virtual network and NSG | `vnet-<suffix>`, `nsg-cae-<suffix>` | eastus2 |
| Azure AI Foundry (`gpt-5.6-sol`, `text-embedding-3-large`) | `ai-<suffix>` | eastus2 |
| Azure AI Search, index `rag-docs` | `srch-<suffix>` | **centralus** |
| Container Registry | `cr<suffix>` | eastus2 |
| Application Insights, Log Analytics | `appi-<suffix>`, `log-<suffix>` | eastus2 |

Two changes were needed during deployment:

1. **VNet injection.** An Azure Policy in the deployment tenant denies Container Apps environments without a virtual network. [network.bicep](deployment/infra/modules/network.bicep) now creates a VNet with a delegated `/23` subnet and an NSG with default rules only. The skip tag the policy offers was not used.
2. **Search region.** eastus2 returned `InsufficientResourcesAvailable` for Azure AI Search. The new `searchLocation` parameter (`AZURE_SEARCH_LOCATION`) places Search in centralus; everything else stays in eastus2.

Verification:

| Check | Result |
| --- | --- |
| `azd up` | Succeeded (provision 17 min, of which the VNet environment took 15; deploy 2 min with ACR Tasks remote build) |
| Ingestion job execution | `Succeeded`: 5 files, 22 chunks uploaded |
| Index `rag-docs` | 22 documents |
| App Insights `AppEvents` | `RagIngestRun`, role `rag-ingest`, status `success`, measurements present |
| Local `/ask` (operator identity) | In-corpus questions answered with `[S1, S2]` citations; out-of-corpus question returned `not_found` |

The API has no ingress. To open it, follow step 6 of [deployment/README.md](deployment/README.md). To remove everything, run `azd down --purge` from `deployment/`.
## Stages at a Glance

| # | Stage | Runs as | Trigger | Result |
| --- | --- | --- | --- | --- |
| 0 | Prepare identity | Operator | Once | `az` signed in as you; azd set to use that sign-in (`auth.useAzCliAuth`) |
| 1 | Provision | Operator (azd, Bicep) | `azd provision` / `azd up` | All Azure resources and role assignments |
| 2 | Create the index | Operator (postprovision hook) | After every provision | Index `rag-docs` with vector, keyword and semantic configuration |
| 3 | Build and deploy | Operator (azd) | `azd deploy` / `azd up` | One image in ACR, used by both the API and the job |
| 4 | Seed | `id-ingest` (job) or the operator (locally) | Once, manually | Every sample document chunked, embedded and indexed |
| 5 | Query | `id-api` | Each request | A cited answer, `not_found`, or passages |
| 6 | Consume | Operator, or an app identity added on purpose | Application calls | Answers inside an application |
| 7 | Update | `id-ingest` | Daily cron, or on demand | Only changed files re-embedded; deleted files removed |
| 8 | Operate | Operator | Ongoing | Logs, metrics, alerts, cost checks |
| 9 | Rebuild (blue/green) | Operator, then `id-ingest` | Model, dimension or schema change | A new index filled, then the app switched over |
| 10 | Tear down | Operator | When finished | `azd down --purge` removes everything |

## Stage 0: Prepare Identity

**Purpose.** Make sure access is granted to the right person and nobody else.

**Steps.**

1. Run `az login`, then `azd config set auth.useAzCliAuth true` so azd deploys as that same user.
2. Do not set `AZURE_PRINCIPAL_ID`. azd resolves your object ID from the signed-in user during each provision and does not store it.

**Safety.** The `preprovision` hook ([check-identity.ps1](deployment/scripts/check-identity.ps1)) stops provisioning if:

- azd is not set to use the Azure CLI sign-in;
- the Azure CLI is signed in as a service principal;
- the tenant or subscription does not match;
- an `AZURE_PRINCIPAL_ID` is present and does not match the signed-in user;
- any other person or group still holds a role in the resource group (for example, a previous operator). The hook prints the delete command for each one;
- API ingress is on for a client ID that was never verified.

This prevents a stale ID, a different azd sign-in, or a leftover grant from giving access to someone else. Object IDs and user names are never written into any file in this folder.

**Optional.** Exposing the API takes two verified steps. [create-api-app-registration.ps1](deployment/scripts/create-api-app-registration.ps1) creates and verifies the Entra app registration, and `azd provision` deploys Easy Auth with ingress still off. [enable-api-ingress.ps1](deployment/scripts/enable-api-ingress.ps1) then checks the deployed Easy Auth configuration, and a second `azd provision` turns on ingress. Without these steps, the API has no ingress at all.

## Stage 1: Provision

**Purpose.** Create every Azure resource from code.

[main.bicep](deployment/infra/main.bicep) creates the resource group, then calls one module per concern:

| Module | Creates | Key security settings |
| --- | --- | --- |
| `identity` | `id-api-*`, `id-ingest-*` user-assigned identities | One identity per workload |
| `monitoring` | Log Analytics, Application Insights | `DisableLocalAuth: true` (Entra-only telemetry ingestion) |
| `search` | AI Search (Basic, semantic ranker free tier) | `disableLocalAuth: true` (no API keys) |
| `ai` | Foundry (AIServices) account, embedding and GPT-5.6 deployments | `disableLocalAuth: true`; deployments created one after the other |
| `acr` | Container Registry (Basic) | Admin user disabled |
| `roles` | 12 role assignments, each scoped to one resource | Data-plane roles only for workloads |
| `containerapps-env` | Container Apps environment | Logs through diagnostic settings, no shared workspace key |
| `fetch-image` | Nothing (lookup only) | Keeps the deployed image when you re-provision |
| `api` | API Container App (scale 0–2) and Easy Auth | Easy Auth only when `API_AUTH_CLIENT_ID` is set; ingress only after `enable-api-ingress.ps1` verifies it |
| `ingest-job` | Ingestion job | No ingress; parallelism 1; manual until the schedule is enabled |

The role assignments are listed in full in [SECURITY-REVIEW.md](SECURITY-REVIEW.md#identity-and-access-matrix).

## Stage 2: Create the Index

**Purpose.** Define the index schema before any data arrives.

**Who.** The `postprovision` hook ([create-search-index.ps1](deployment/scripts/create-search-index.ps1)) runs as the operator, because only the operator holds Search Service Contributor. The workloads cannot change the schema.

**How.** It reads [rag-docs.index.json](deployment/index/rag-docs.index.json), sets the index name and vector dimensions from azd outputs, and sends a create-or-update request with an Entra token. It retries while new role assignments propagate.

**Schema.**

- **Text:** `title` and `content`, searchable with the `en.microsoft` analyzer.
- **Vector:** `content_vector`, 3,072 dimensions, HNSW, cosine, `stored: false` to save space.
- **State:** `source_path`, `content_hash`, `chunk_ordinal`, `chunk_count`, `source_commit`, `ingested_at`.
- **Semantic configuration:** `default` (title and content).

## Stage 3: Build and Deploy

**Purpose.** Ship the code.

azd builds one image from [src/Dockerfile](src/Dockerfile) in Azure: it uploads the build context (filtered by [.dockerignore](.dockerignore)), and ACR Tasks builds the image and pushes it to the same registry. The operator needs AcrPush and Container Registry Tasks Contributor on the registry; no local Docker is needed. azd points both the API and the job at the image. The job and the API pull it with their own identities (AcrPull). The container:

- runs as a non-root user (uid 10001);
- includes `git` for Git sources;
- includes `sample-data/`.

`RAG_ROLE` decides whether a container serves the API or runs ingestion.

## Stage 4: Seed

**Purpose.** Fill the index for the first time. See [howto/01-seed.md](howto/01-seed.md).

**Pipeline** ([ingest.py](src/rag/ingest.py)):

1. **Load.** Read Markdown from `sample-data/` or a Git repository. Git URLs must be HTTPS on an allow-listed host. Files and totals have size limits, and symbolic links are ignored.
2. **Read state.** List what the index already holds.
3. **Plan.** Compare each file's SHA-256 hash with the index. `seed` re-embeds everything; `update` handles only changes.
4. **Guard.** Stop without changes if:
   - the source is empty, or
   - more than `RAG_MAX_DELETE_FRACTION` (default 50%) of the indexed chunks would be lost, counting removed files and files that now yield fewer chunks.
5. **Chunk.** Split by Markdown heading into chunks of about 3,000 characters with a small overlap, never more than 6,000 bytes. Each chunk ID is stable and derived from the path and position.
6. **Embed.** Embed in batches of 16 with `text-embedding-3-large` and check the vector length.
7. **Upload.** Write in batches of 50. Throttling and conflicts (409, 422, 429, 503) get up to 4 attempts with exponential backoff. Any other failure stops the run.
8. **Delete.** Remove stale chunks **after** all uploads succeed.

**Why this order.** A crash at any point leaves the index at least as complete as before. Running it again repairs it, and running it twice creates no duplicates.

Use `--dry-run` to see the plan without changing anything.

## Stage 5: Query

**Purpose.** Answer a question with evidence. See [howto/03-query.md](howto/03-query.md).

1. **Authenticate.** Easy Auth accepts only a valid Entra token for the API, from an allowed client application, belonging to the operator's object ID. The app checks the principal again.
2. **Retrieve.** Embed the question, then run a hybrid query: keyword search plus a 50-nearest-neighbor vector search, re-ranked by the semantic ranker. The top 5 passages are kept.
3. **Gate.** If the best semantic reranker score is below `RAG_MIN_RERANKER_SCORE` (default 1.5 on a 0–4 scale), return `not_found` without calling the language model. A missing score also counts as "not found".
4. **Generate.** Send the passages to GPT-5.6, labeled `S1`..`S5`, as untrusted data. Request JSON in which every sentence cites labels. Settings:
   - `reasoning_effort: low`
   - `max_completion_tokens: 4000`
   - no `temperature`, because GPT-5-family reasoning models do not accept it
5. **Validate.** Reject output that is not valid JSON, has sentences without citations, or cites labels that were not provided. Rejected output becomes `not_found`.

`mode: "extractive"` stops after step 3 and returns passages only, with no model-written text.

## Stage 6: Consume

**Purpose.** Use the system from an application. There are three patterns: the HTTP API, search only, or the embedded Python package. They are described in the [top-level README](README.md#how-an-application-consumes-this) and in [howto/04-consume.md](howto/04-consume.md).

## Stage 7: Update and Refresh Plan

**Purpose.** Keep the index in step with the source repository. See [howto/02-update-and-refresh-plan.md](howto/02-update-and-refresh-plan.md).

| Event | Action | Mode |
| --- | --- | --- |
| Normal document edits | Daily scheduled job at 06:00 UTC (`ENABLE_INGEST_SCHEDULE=true`) | `update` |
| Urgent edit or large merge | `az containerapp job start` | `update` |
| Chunker or embedding-text logic changed | Increase `CHUNKER_VERSION` in `chunker.py`. It is part of every file hash, so the next run re-chunks every file. Alternatively, run `seed`. | `update` |
| Embedding model or dimensions changed | Blue/green rebuild (Stage 9) | `seed` into a new index |
| Index schema changed | Blue/green rebuild (Stage 9) | `seed` into a new index |
| Delete guard tripped | Confirm the source is correct, then raise `RAG_MAX_DELETE_FRACTION` for one run | `update` |

**Schedule.** Keep the schedule off until the first seed has been checked, so a misconfigured source cannot run unattended.

## Stage 8: Operate

**Purpose.** Know whether the system is healthy. See [howto/05-operate.md](howto/05-operate.md).

**Where telemetry goes.**

- Application traces go to Application Insights through Entra-authenticated ingestion.
- Each container sends custom events: `RagApiCall` for every API call and `RagIngestRun` for every job run. Each event names the container (`cloud_RoleName` is `rag-api` or `rag-ingest`) and records the status, HTTP status, duration and, on failure, the exception type.
- Platform logs for Search, AI Services and Container Apps go to Log Analytics.

**What is logged.** Status, counts and timings, but never question or answer text.

**What to watch.**

- Job failures.
- The share of `not_found` answers.
- Search throttling (HTTP 429).
- Model token use against quota.

## Stage 9: Rebuild (Blue/Green)

**Purpose.** Change something that an in-place update cannot change: embedding model, dimensions or field types.

The new index is built and seeded **before** the API switches to it, so users never query an empty index.

1. From `deployment/`, create the new index: `$env:AZURE_SEARCH_INDEX='rag-docs-v2'; pwsh ./scripts/create-search-index.ps1`. The script prefers process environment variables over azd values.
2. From `src/`, seed it locally with `AZURE_SEARCH_INDEX=rag-docs-v2`: `python -m rag.ingest seed`.
3. Verify answers locally against the new index.
4. Switch: `azd env set RAG_INDEX_NAME rag-docs-v2`, then `azd provision`. The API and job now use the new index.
5. After a soak period, delete the old index.

To roll back, set `RAG_INDEX_NAME` back to the previous name and run `azd provision` again. The old index is untouched until step 5.

Full steps: [howto/02-update-and-refresh-plan.md](howto/02-update-and-refresh-plan.md#blue-green-rebuild).

## Stage 10: Tear Down

Run `azd down --purge` from `deployment/`. It deletes the resource group and purges the soft-deleted AI Services account. If you created the optional app registration, delete it separately: `az ad app delete --id <API_AUTH_CLIENT_ID>`.

## Key Design Decisions

| Decision | Why |
| --- | --- |
| The index itself is the ingestion state store | No extra storage account. Hashes, ordinals and counts let a rerun detect and repair incomplete files. |
| Upload, then delete | A failed run never removes good data. |
| Hybrid search plus semantic ranker | Keywords catch exact terms such as error codes; vectors catch paraphrases; the ranker orders both. |
| Relevance gate before generation | Saves model cost and avoids answering from weak evidence. The threshold is a starting heuristic; tune it against real questions. |
| JSON with per-sentence citations | Lets code reject uncited or invented citations. |
| One image, two roles | One build and one vulnerability surface to patch. |
| User-assigned identities | Each identity exists before its app does, so roles are in place on first start and survive app re-creation. |
| Operator creates the index | Workloads hold data-plane roles only and cannot change or delete the schema. |
| API locked until an app registration exists and Easy Auth is verified | The secure default is unreachable rather than open. |

## Open Assumptions

These are not verified and will be confirmed only by a real deployment:

1. **GPT-5.6 availability.** `gpt-5.6-sol` version `2026-07-09` and `text-embedding-3-large` are available with GlobalStandard quota in `eastus2` for this subscription. If not, change `location` or the model parameters.
2. **App registrations.** Tenant policy allows the operator to create an app registration and pre-authorize the Azure CLI. If not, a tenant admin runs [create-api-app-registration.ps1](deployment/scripts/create-api-app-registration.ps1), or the API stays locked and you query locally.
3. **Policy.** Management-group policy may require private endpoints, tags or other settings that would block provisioning.
4. **azd behavior.**
   - azd makes Bicep outputs available to the `postprovision` hook. The script falls back to `azd env get-value` either way.
   - azd deploys a Container Apps Job through `host: containerapp`.
   - azd accepts service projects outside the `azure.yaml` folder (`project: ../src`).
5. **Placeholder images.** Before the first deploy, the placeholder images start cleanly. The API placeholder is assumed to listen on 8080.
6. **Spoofed headers.** Easy Auth replaces any `X-MS-CLIENT-PRINCIPAL-*` header sent by a client. The app's own check is defense in depth, not the primary control.
7. **Relevance threshold.** The 1.5 threshold is a heuristic and needs tuning with real questions.
8. **Easy Auth without ingress.** A Container Apps `authConfigs` resource can be deployed while the app has no ingress, so it can be verified before ingress opens.
9. **azd identity settings.** `azd config get auth.useAzCliAuth` prints `true` (with or without quotes), and azd resolves `AZURE_PRINCIPAL_ID` from the signed-in user during provisioning. The preprovision hook may not see that value; the check runs only when it is present.
10. **Entra ID behavior.** Microsoft Graph may make the creating user an owner of the new app registration. The check allows only you as owner. Global Administrators may be able to get a token even with assignment required; the Easy Auth principal policy and the app's own check still reject them.
