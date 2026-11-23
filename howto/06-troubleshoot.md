# Troubleshoot

Find the symptom, then apply the fix. For deployment-time failures (quota, policy, `azd up`), also see [../deployment/README.md](../deployment/README.md#troubleshooting-deployment).

## Calling the API

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| No `API_URL`, or the URL does not resolve | Locked mode: no app registration, or ingress not yet verified and enabled | Expected. Query locally ([03-query.md](03-query.md)) or register and enable the API ([../deployment/README.md](../deployment/README.md#6-choose-how-the-api-is-reached)) |
| 401 | Missing or expired token, wrong audience, or the caller's client app is not allowed | Request the token for `api://<API_AUTH_CLIENT_ID>/.default` from the Azure CLI as the operator |
| `AADSTS50105` when requesting a token | Your account is not assigned to the app registration | Assign yourself on the enterprise application, then sign in again |
| 403 `Forbidden` | Easy Auth accepted the token, but your object ID is not in `ALLOWED_PRINCIPAL_IDS` | You are signed in as a different user than the one who provisioned. Sign in as the operator, then `azd provision` |
| 422 | Question longer than `RAG_MAX_QUESTION_CHARS`, or a malformed body | Shorten it, or send `{"question": "..."}` |
| 502 `Upstream service error` | Search or model call failed | Check `AppExceptions` for the same time ([05-operate.md](05-operate.md)) |
| First call takes 10–30 seconds | Scale from zero | Expected; set `minReplicas: 1` in `api.bicep` if it matters |

## Answers

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `not_found` for everything | Empty index, or the threshold is too strict | Check the document count ([01-seed.md](01-seed.md)); try `mode: "extractive"`; tune `RAG_MIN_RERANKER_SCORE` ([03-query.md](03-query.md#tuning-relevance)) |
| `not_found` with `reason=invalid_citations` in logs | The model's output did not cite every sentence | Usually a hard or ambiguous question; rephrase. Frequent occurrences suggest raising `RAG_REASONING_EFFORT` to `medium` |
| Answer cites the wrong passage | Citation checks only that labels exist, not that the passage supports the sentence | Known limit; spot-check, and improve source headings |
| `Embedding dimensions do not match the index` | `AZURE_OPENAI_EMBEDDING_DIMENSIONS` differs from the index's vector field | Use the value the index was built with, or rebuild with blue/green ([02-update-and-refresh-plan.md](02-update-and-refresh-plan.md#blue-green-rebuild)) |

## Ingestion Job Fails

The job writes the failure reason to stderr (`ContainerAppConsoleLogs`, or your terminal when you run it locally). `AppTraces` records only `ingestion failed: <error type>`. Run `python -m rag.ingest update --dry-run` locally to see the plan without writing anything.

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `Source returned no files; refusing to continue` | Wrong path, include pattern, or Git ref | Check `RAG_SOURCE_PATH`, or `RAG_GIT_INCLUDE` and `RAG_GIT_REF`; run `--dry-run` |
| `Local source folder not found` | `RAG_SOURCE_PATH` is wrong | In the container it is `/app/sample-data`; locally, a path relative to `src` |
| `Plan removes N of M chunks, above RAG_MAX_DELETE_FRACTION` | More than half the indexed chunks would be deleted | Confirm the source is right. If the removal is intended, raise `RAG_MAX_DELETE_FRACTION` for one local run |
| `Source exceeds the file-count or size limit` | Above 2,000 files or 50 MB | Narrow `RAG_GIT_INCLUDE` |
| A file's content disappeared from answers | The file grew above 1 MB or is not UTF-8, so it was skipped and its chunks removed | Split or re-encode the file |
| `Git host '...' is not in RAG_GIT_ALLOWED_HOSTS` | Host not allowed | Add it only if you trust it |
| `Git URL must ...` or `Git ref contains unsupported characters` | URL has credentials, a query, or is not HTTPS; or the ref is malformed | Use a plain public `https://` URL and a branch or tag name |
| `git clone failed with exit code 128` (or `git timed out`) | Private repository, wrong ref, or network | Only public HTTPS repositories are supported; check the ref exists |
| `Ingestion failed` with `ingestion failed: HttpResponseError` | Usually a missing role (403), roles still propagating, or a missing index (404) | Wait 5–10 minutes after `azd provision`; check `az role assignment list`; rerun `deployment/scripts/create-search-index.ps1` |
| `N documents still failed after retries` | Throttling (429/503) outlasted 4 attempts | Rerun later; for repeated failures raise model capacity |
| `AZURE_CLIENT_ID is required when running in Azure` | The container lost its identity setting | Re-provision; the Bicep sets `AZURE_CLIENT_ID` for both containers |

Because writes are keyed by chunk ID, rerunning a failed job is safe and converges.

## Platform

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ImagePullBackOff` in `ContainerAppSystemLogs` | AcrPull not yet effective, or the image tag does not exist | Wait for role propagation; run `azd deploy` |
| Container keeps restarting | Missing required setting at startup | Read `ContainerAppConsoleLogs`; settings errors name the variable |
| No rows in `AppTraces` | Telemetry needs both the App Insights connection string and the managed identity client ID; the identity needs Monitoring Metrics Publisher | Check both variables and the role; data can take 5 minutes to appear |
| `azd provision` fails on a role assignment that already exists | The assignment was created outside this template with a different name | Delete the duplicate assignment, then provision again |
| `azd down` leaves the app registration | It is created by a script, not Bicep | `az ad app delete --id <API_AUTH_CLIENT_ID>` |
| `azd deploy` fails with `AuthorizationFailed` on `scheduleRun` or `listBuildSourceUploadUrl` | Container Registry Tasks Contributor not yet effective for you | Wait a few minutes for role propagation, then `azd deploy` again. Run `azd provision` first if the role is missing |
| `azd deploy` reports that remote build is unavailable, then tries local Docker | ACR Tasks is not available for this registry or subscription | Run `az acr build --registry <registry> --file src/Dockerfile .` from `azure-rag-example` to confirm. If Tasks is blocked, install Docker and remove `remoteBuild: true` from `azure.yaml` |
| The remote build fails with a `COPY` error | A file the Dockerfile needs is excluded by `.dockerignore` | Check [../.dockerignore](../.dockerignore); the build needs `src/requirements.txt`, `src/rag`, `src/main.py` and `sample-data` |
