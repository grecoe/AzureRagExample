# Operate the System

## Where to Look

| Signal | Location | Table |
| --- | --- | --- |
| API and job application logs (`rag.*` loggers) | Application Insights, workspace-based | `AppTraces`, `AppExceptions` in Log Analytics |
| Custom events `RagApiCall` and `RagIngestRun` | Application Insights (`appi-*`) | `customEvents` in Application Insights; `AppEvents` in Log Analytics |
| API requests and outbound calls | Application Insights | `requests`, `dependencies` (`AppRequests`, `AppDependencies`) |
| Container stdout and stderr | Log Analytics | `ContainerAppConsoleLogs` |
| Container platform events (start, crash, scale, image pull) | Log Analytics | `ContainerAppSystemLogs` |
| Search and AI Services operations | Log Analytics | `AzureDiagnostics` |
| Platform metrics | Azure Monitor metrics on each resource | — |

Logs keep counts, statuses and timings. They never contain question or answer text.

## Custom Events

Each container identifies itself. In Application Insights, `cloud_RoleName` is `rag-api` or `rag-ingest` (from `RAG_ROLE`), and `cloud_RoleInstance` is the replica or job execution name. Every event also carries `customDimensions.container`.

| Event | Sent when | Dimensions | Measurements |
| --- | --- | --- | --- |
| `RagApiCall` | Every `POST /ask` and `POST /search`, including rejected and failed calls | `container`, `operation` (`ask`, `search`), `status`, `http_status`, `error_type`, `answer_status` (`/ask` only) | `duration_ms` |
| `RagIngestRun` | Every job run, after it finishes or fails | `container`, `mode` (`seed`, `update`), `dry_run`, `status`, `error_type` | `duration_ms`, `source_files`, `changed_files`, `unchanged_files`, `planned_chunks`, `planned_deletes`, `removed_files`, `uploaded_chunks`, `deleted_chunks` |

| `status` | Meaning |
| --- | --- |
| `success` | The call or run completed |
| `not_found` | The call completed, but no sufficient evidence or passages were found |
| `dry_run` | The run printed its plan and changed nothing |
| `client_error` | The request was invalid (HTTP 4xx other than 401 or 403), such as a question that is too long |
| `forbidden` | The caller is not allowed (HTTP 401 or 403) |
| `failed` | An upstream or unexpected error (HTTP 5xx or a failed job). `error_type` holds the exception type name only. |

Counts that a failed run never reached are absent. The job exports its telemetry before it exits. Requests that Easy Auth rejects never reach the container, so they produce no event; see the platform logs for those.

Open the resource named by `azd env get-value AZURE_APPLICATION_INSIGHTS_NAME`, select **Logs**, and run:

```kusto
customEvents
| where timestamp > ago(1d)
| where name in ("RagApiCall", "RagIngestRun")
| extend status = tostring(customDimensions.status)
| summarize Calls = count(), P95Ms = percentile(todouble(customMeasurements.duration_ms), 95)
    by cloud_RoleName, name, status
| order by cloud_RoleName asc, Calls desc
```

The same data in the Log Analytics workspace:

```kusto
AppEvents
| where TimeGenerated > ago(1d)
| where Name in ("RagApiCall", "RagIngestRun")
| summarize Calls = count() by AppRoleName, Name, Status = tostring(Properties.status)
```

Recent ingestion runs:

```kusto
customEvents
| where timestamp > ago(7d) and name == "RagIngestRun"
| project timestamp, cloud_RoleInstance, mode = tostring(customDimensions.mode),
          status = tostring(customDimensions.status), error_type = tostring(customDimensions.error_type),
          uploaded = todouble(customMeasurements.uploaded_chunks), deleted = todouble(customMeasurements.deleted_chunks),
          duration_ms = todouble(customMeasurements.duration_ms)
| order by timestamp desc
```

Open the Log Analytics workspace (`log-*`) in the portal and use **Logs**. Table names are the Azure defaults for these settings; confirm them in the workspace schema after the first deployment.

## Useful Queries

Answer outcomes over the last day:

```kusto
AppTraces
| where TimeGenerated > ago(1d)
| where Message startswith "answered" or Message startswith "not_found"
| extend Outcome = tostring(split(Message, " ")[0]),
         Reason  = extract(@"reason=(\w+)", 1, Message)
| summarize Count = count() by Outcome, Reason
| order by Count desc
```

Ingestion runs over the last week:

```kusto
AppTraces
| where TimeGenerated > ago(7d)
| where Message startswith "plan " or Message startswith "complete " or Message startswith "ingestion failed"
| project TimeGenerated, Message
| order by TimeGenerated desc
```

Search throttling over the last day:

```kusto
AzureDiagnostics
| where TimeGenerated > ago(1d)
| where ResourceProvider == "MICROSOFT.SEARCH"
| summarize Requests = count(), Throttled = countif(resultSignature_d == 429) by bin(TimeGenerated, 1h)
| order by TimeGenerated asc
```

Container crashes and image pulls:

```kusto
ContainerAppSystemLogs
| where TimeGenerated > ago(1d)
| where Reason in ("BackOff", "ContainerCrashing", "ImagePullBackOff", "PullingImage", "ContainerTerminated")
| project TimeGenerated, ContainerAppName, Reason, Log
| order by TimeGenerated desc
```

## Health Checklist

| Check | Healthy | If not |
| --- | --- | --- |
| Last job execution | `Succeeded` within the last day (with schedule on) | [06-troubleshoot.md](06-troubleshoot.md#ingestion-job-fails) |
| `not_found` share | Steady. A jump after a refresh suggests missing content. | Compare document counts before and after |
| Search 429s | Near zero | Add a replica, or lower `RAG_MAX_CONCURRENT_ANSWERS` |
| Model 429s | Near zero | Raise deployment capacity (`chatCapacity`, `embeddingCapacity`) |
| Document count | Stable or growing as expected | Check the delete guard and the source |

## Alerts Worth Adding

None are deployed. Add these as Azure Monitor alerts when the system matters:

1. A job execution failed (Container Apps Job metric, or a log alert on `RagIngestRun` with `status == "failed"`).
2. No successful job execution in 26 hours while the schedule is on.
3. The `not_found` share above your baseline for an hour, or any `RagApiCall` with `status == "failed"`.
4. Model token use above 80% of the deployment's per-minute quota.

## Cost Drivers

| Resource | What drives cost | Notes |
| --- | --- | --- |
| AI Search Basic | Fixed hourly price | The largest fixed cost. `azd down` stops it. |
| Semantic ranker | Free tier: 1,000 requests a month | Above that, switch the plan to `standard` |
| GPT-5.6 | Input, reasoning and output tokens per answer | `extractive` mode avoids it |
| Embeddings | Tokens embedded | `update` embeds only changed files |
| Container Apps | Active seconds | Scales to zero; the job runs only on demand or schedule |
| Log Analytics | GB ingested | 30-day retention |

## Routine Tasks

| Task | How often | How |
| --- | --- | --- |
| Patch the image | Monthly, or on a base-image CVE | `azd deploy` rebuilds from the latest `python:3.12-slim-bookworm`; pin by digest for production |
| Upgrade Python packages | Quarterly | Update `src/requirements.txt`, run the tests, `azd deploy` |
| Review access | Quarterly | `az role assignment list --scope <rg-id> --include-inherited -o table`; app registration assignments |
| Check model retirement dates | Quarterly | Azure AI Foundry model list; plan a blue/green rebuild for embedding changes |
