# Security Review

**Verdict.** The design meets both stated goals for a sample over public data:

1. **Services authenticate with managed identities.** No keys, connection secrets or client secrets exist. Every service that supports it has local (key) authentication disabled.
2. **Only you can use the system.** You are the only human principal with direct role assignments, and the only principal the API admits.

The main remaining risks are public network endpoints, inherited subscription-level access that this template cannot remove, and prompt injection from indexed content. See [Residual Risks](#residual-risks) and [Hardening for Production](#hardening-for-production).

Scope: everything under this folder, as written. A proof of concept is now deployed in `<resource-group>` (see [REPORT.md](REPORT.md#deployment-status)). The Container Apps environment is VNet-injected because tenant policy requires it. Statements about runtime behavior not listed in that verification still need checking ([Verify After Deployment](#verify-after-deployment)).

## Principals

| Principal | Kind | Used by | Credential |
| --- | --- | --- | --- |
| Operator (you) | Entra user, `principalType: User` only | `azd` (set to use the Azure CLI sign-in), `az`, the hooks, local runs | Your interactive sign-in. azd resolves the object ID from that sign-in during each provision, and the scripts resolve it with `az ad signed-in-user show`. It is never written to any file. |
| `id-api-*` | User-assigned managed identity | API container | Federated by the platform; selected with `AZURE_CLIENT_ID` |
| `id-ingest-*` | User-assigned managed identity | Ingestion job | Same |
| API app registration (optional) | Entra application, single-tenant | Easy Auth token validation | None. It has no secret or certificate; it only defines the token audience. |
| Azure CLI (`04b07795-...`) | Microsoft first-party public client | Getting a token for the API | Your sign-in |

The two workloads have separate identities, so the API cannot write to the index and its compromise cannot change content.

## Identity and Access Matrix

Every assignment is scoped to a single resource, never the resource group or subscription.

| Resource | Operator | `id-api` | `id-ingest` |
| --- | --- | --- | --- |
| Azure AI Search | Search Service Contributor (create the index); Search Index Data Contributor (seed locally, inspect) | Search Index Data Reader | Search Index Data Contributor |
| Azure AI Foundry (AI Services) | Cognitive Services OpenAI User | Cognitive Services OpenAI User | Cognitive Services OpenAI User |
| Container Registry | AcrPush; Container Registry Tasks Contributor (`azd deploy` remote build: upload context, schedule run, read logs) | AcrPull | AcrPull |
| Application Insights | — (reads through inherited access) | Monitoring Metrics Publisher | Monitoring Metrics Publisher |
| API (Easy Auth) | Sole assigned user; sole allowed principal | — | — |
| Ingestion job | Start it (inherited control-plane access) | — | — |

Definitions are in [deployment/infra/modules/roles.bicep](deployment/infra/modules/roles.bicep). Assignment names are deterministic GUIDs, so re-provisioning does not duplicate them.

**Inherited access.** Anyone with Owner, Contributor or a similar role on the subscription or a management group can still manage these resources, and Owner can grant data roles. This template cannot remove inherited access. "Only you" means only you **as granted by this template**.

**Leftover grants.** Deterministic assignment names keep re-provisioning idempotent, but they also mean a new operator does not replace an earlier operator's assignments. The preprovision hook therefore lists every role assignment at or below the resource group. It stops if any person or group other than you holds one, and prints the `az role assignment delete --ids` command for each. Service principals, including the two managed identities, are not checked.

Audit everything, including assignments on each resource and inherited ones:

```powershell
$rgId = az group show -n <resource-group> --query id -o tsv
az role assignment list --all -o json | ConvertFrom-Json |
    Where-Object { $_.scope -ieq $rgId -or $_.scope -ilike "$rgId/*" } |
    Format-Table principalType, roleDefinitionName, scope
az role assignment list --resource-group <resource-group> --include-inherited -o table
```

**Control plane versus data plane.** Contributor on the resource group does **not** grant Search or OpenAI data roles, because keys are disabled. A Contributor could, however, re-enable keys, change the API's settings, or attach a managed identity to their own workload. That is why the inherited-access audit matters.

## How the API Admits a Caller

Three independent checks, in order:

| Layer | Check | Configured in |
| --- | --- | --- |
| Microsoft Entra ID | `appRoleAssignmentRequired=true` and only you are assigned, so other users cannot get a token for this API. Global Administrators may be an exception; the next two layers still reject them. | `scripts/create-api-app-registration.ps1` |
| Easy Auth (platform) | Valid v2 token from your tenant; audience is the API; client is the Azure CLI; `oid` is you. Otherwise 401 or 403 | `modules/api.bicep` (`authConfigs`) |
| Application | `X-MS-CLIENT-PRINCIPAL-ID` must be in `ALLOWED_PRINCIPAL_IDS` (you). Otherwise 403 | `src/rag/app.py` |

The Azure CLI is a public client anyone can use, so the client check alone restricts little. The real controls are the assignment requirement and the principal check.

In **locked mode** (the default), the API has no ingress at all, so none of this is reachable from any network.

**Ingress opens in two verified steps.** Easy Auth and ingress are never turned on in the same deployment:

1. `create-api-app-registration.ps1` creates the registration through Microsoft Graph, reads it back, and verifies it before saving the client ID.
2. `azd provision` deploys the Easy Auth configuration. Ingress stays off (`apiIngressEnabled` is `false`).
3. `enable-api-ingress.ps1` verifies the registration again and checks the Easy Auth configuration that is actually deployed: platform on, `Return401`, client ID, issuer, audiences, the Azure CLI as the only client, and you as the only principal. It also checks the container's `AUTH_MODE` and `ALLOWED_PRINCIPAL_IDS`. Only then does it set `API_INGRESS_ENABLED`.
4. A second `azd provision` turns on ingress.

If `API_AUTH_CLIENT_ID` changes after verification, the preprovision hook stops until ingress is turned off and verified again.

## Data Flows

| Flow | Transport | Authentication |
| --- | --- | --- |
| You to API | HTTPS only (`allowInsecure: false`) | Entra token for `api://<client-id>` |
| API or job to AI Search | HTTPS | Managed identity token, keys disabled |
| API or job to AI Foundry | HTTPS, `/openai/v1/` | Managed identity token, keys disabled |
| Containers to Registry (image pull) | HTTPS | Managed identity, admin user disabled |
| Job to GitHub (Git source only) | HTTPS only; other protocols and redirects refused | None; public repositories only |
| Telemetry to Application Insights | HTTPS | Managed identity; instrumentation-key ingestion disabled |
| Platform logs to Log Analytics | Azure diagnostic settings | Platform-managed; workspace shared keys disabled |
| You to Search (index creation, local runs) | HTTPS | Your Entra token |

## Secrets

There are none to manage:

- AI Search, AI Foundry and Application Insights have local authentication disabled.
- The Log Analytics workspace has shared keys disabled.
- The registry admin user is off.
- The app registration has no client secret or certificate. Both registration scripts check this on the app and its service principal.
- The Application Insights connection string is set as an environment variable. With local authentication off, it is an address, not a credential.
- Private Git repositories are not supported, so no Git credentials exist. Credentials in a Git URL are rejected.
- Microsoft Graph tokens and request bodies stay in memory; the scripts write no temporary files.

Key Vault is therefore not needed. Add it only if you introduce a secret, such as a private Git token.

## Threat Review

| # | Threat | Category | Control | Residual |
| --- | --- | --- | --- | --- |
| T1 | Another user calls the API | Spoofing | No ingress by default. Ingress opens only after the deployed Easy Auth is verified. Then: assignment required, allowed principals, app check | Low |
| T2 | A caller forges `X-MS-CLIENT-PRINCIPAL-ID` | Spoofing | Easy Auth replaces identity headers before the app sees the request; locked mode has no ingress | Low (assumed platform behavior; verify) |
| T3 | A stolen token of yours is replayed | Spoofing | Short-lived tokens, HTTPS only, optional IP allow-list (`apiAllowedIpRanges`) | Medium: anyone holding your token can call until it expires |
| T4 | The wrong person is made operator, or keeps access | Elevation | azd must use the Azure CLI sign-in; the hook checks user type, tenant, subscription and any `AZURE_PRINCIPAL_ID`; it stops if another person or group holds a role in the resource group; `principalType` must be `User` | Low |
| T5 | A compromised API writes or deletes index content | Tampering | The API holds only Search Index Data Reader | Low |
| T6 | A malicious or broken source wipes the index | Tampering | Source loads first; guards stop empty sources and net chunk loss above 50%, including files that shrink | Low |
| T7 | Indexed content contains instructions to the model (prompt injection) | Tampering | Sources are fenced as untrusted data; JSON output; each answer item must cite a supplied label (checked per item, not per sentence); no tools are available to the model; answers are returned to you only | Medium: injected text can still shape answer wording |
| T8 | Git source is redirected or abused | Tampering, information disclosure | HTTPS only, host allow-list, no redirects, no credentials, no symlinks, path containment, no shell, git output not echoed. Size and count limits apply after the clone, so they do not bound download size. | Low |
| T9 | Sensitive data indexed by mistake | Information disclosure | Default source is the bundled sample data; Git sources must be public | Medium if pointed at the wrong repository. Index only public content. |
| T10 | Question or answer text leaks into logs | Information disclosure | App logs and custom events carry counts, statuses, durations and container names only; failures record only the exception type, never its message or stack; no request bodies or principal IDs are logged. Tests assert that question text and exception messages do not reach events. | Low. Platform diagnostic logs may record request metadata; check after deployment, including error paths. |
| T11 | Upstream error details reach the caller | Information disclosure | The API returns a generic 502; Swagger is disabled outside local mode | Low |
| T12 | Cost or denial of service through repeated requests | Denial of service | Only you are admitted; at most 4 concurrent `/ask` or `/search` requests per replica and 2 replicas; questions capped at 1,000 characters; model capacity is a hard ceiling | Low while access is operator-only |
| T13 | Overlapping job runs corrupt state | Tampering | One replica per execution (not a global lock); writes are keyed and safe to repeat; later runs converge | Low |
| T14 | Vulnerable or tampered container image | Tampering | Slim official base, non-root user (10001), dependency versions pinned (not hash-locked), registry admin off | Medium: base image not pinned by digest; packages not hash-verified |
| T15 | Re-enabling keys or exposing the API by configuration change | Elevation | Settings are in Bicep, so `azd provision` restores them | Medium: inherited Contributor can change them between deployments |
| T16 | Actions cannot be traced afterwards | Repudiation | Resource diagnostic logs and Azure Activity Log; App Insights traces | Medium: 30-day retention; app logs do not record caller IDs |

## Residual Risks

These are accepted for a sample over public data. Each has a hardening step below.

1. **Public endpoints.** AI Search, AI Foundry and the Registry accept connections from the internet. All still require Entra tokens.
2. **Inherited access** from the subscription or management groups.
3. **Prompt injection** from indexed content (T7). Citation checks show where text came from, not that it is true.
4. **Base image by tag**, not digest (T14).
5. **Default content filters.** The model deployments use the default Microsoft content filtering. No custom policy or Prompt Shields is configured.
6. **Bearer token theft** (T3).
7. **Short retention** (30 days) and no caller ID in app logs (T16).

## Hardening for Production

In priority order:

| # | Change | Addresses |
| --- | --- | --- |
| 1 | Remove or justify inherited Owner and Contributor; use Privileged Identity Management for just-in-time elevation | Residual 2, T15 |
| 2 | Private endpoints for Search, AI Foundry and Registry; the Container Apps environment is already VNet-injected, so add `internal: true` and private DNS; `publicNetworkAccess: Disabled` | Residual 1 |
| 3 | Azure Policy to deny `disableLocalAuth: false` and public network access on these resource types | T15 |
| 4 | Pin the base image by digest and scan images (Microsoft Defender for Containers) | Residual 4 |
| 5 | A custom content filter with Prompt Shields for indirect attacks | Residual 3, 5 |
| 6 | Azure API Management in front of the API for per-caller quotas, if callers are ever added | T12 |
| 7 | Longer retention, and log the caller's object ID (not their name) per request | Residual 7 |
| 8 | Conditional Access requiring a compliant device for the Azure CLI | Residual 6 |
| 9 | Narrow the operator's Search data role to the index scope | Least privilege |

## Verify After Deployment

| Check | Command or step | Expected |
| --- | --- | --- |
| Keys disabled on Search | `az search service show -g <resource-group> -n <srch> --query disableLocalAuth` | `true` |
| Keys disabled on AI Foundry | `az cognitiveservices account show -g <resource-group> -n <ai> --query properties.disableLocalAuth` | `true` |
| Registry admin off | `az acr show -n <cr> --query adminUserEnabled` | `false` |
| Role assignments | The audit commands under [Identity and Access Matrix](#identity-and-access-matrix) (covers the resource group **and** each resource in it) | Only the matrix above, plus inherited roles you recognize |
| Locked mode | `az containerapp show -g <resource-group> -n <ca-api> --query properties.configuration.ingress` | `null` |
| Ingress gate | Before `enable-api-ingress.ps1`, after the first provision with a registration | Easy Auth deployed; ingress still `null` |
| Easy Auth rejects others | Call `/ask` without a token; then request a token as another account | 401; token request fails (`AADSTS50105`) |
| Spoofed header ignored | With your token, call `/search` with `X-MS-CLIENT-PRINCIPAL-ID` set to another GUID | Request still runs as you (Easy Auth overwrites it) |
| No secrets in config | `az containerapp show ... --query properties.configuration.secrets`; app and service principal credentials in Entra ID | Null or empty; no password or key credentials |
| Logs hold no question text | Send a distinctive test question, including one that fails (for example, with the model deployment scaled to zero). Search `AppTraces`, `AppEvents`, `AppExceptions`, `ContainerAppConsoleLogs_CL` and `AzureDiagnostics` | No matches; failures show only an exception type |

## Security Rubber-Duck Results

An independent review of this design found 7 issues. All are fixed in the files as written.

| # | Severity | Finding | Fix | Files |
| --- | --- | --- | --- | --- |
| F1 | High | An earlier operator's role assignments survive a change of operator, because assignment names are deterministic | The preprovision hook stops if any person or group other than you holds a role at or below the resource group, and prints the delete commands | `deployment/scripts/check-identity.ps1` |
| F2 | High | azd could sign in as a different identity from the Azure CLI, so the hook checked one identity and azd granted roles to another | The hook requires `auth.useAzCliAuth=true`, a user sign-in, the expected subscription and tenant, and a matching `AZURE_PRINCIPAL_ID` when one is set | `deployment/scripts/check-identity.ps1` |
| F3 | Medium | Instructions persisted your object ID in the azd environment and wrote Graph request bodies to temporary files | azd resolves the ID during each provision; scripts call Graph with in-memory bodies and tokens | `deployment/scripts/common.ps1`, `create-api-app-registration.ps1`, docs |
| F4 | High | Ingress could open in the same deployment as Easy Auth, before anyone confirmed Easy Auth was correct | Easy Auth deploys first with ingress off; `enable-api-ingress.ps1` verifies the deployed configuration before ingress opens | `deployment/infra/modules/api.bicep`, `infra/main.bicep`, `infra/main.parameters.json`, `scripts/enable-api-ingress.ps1` |
| F5 | Medium | The registration script did not check command results or read back what it created | Graph calls are checked and retried; the registration is read back and verified (single tenant, one scope, Azure CLI only, no credentials, no other owners, you as the only assignee) before it is saved | `deployment/scripts/create-api-app-registration.ps1`, `common.ps1` |
| F6 | Medium | Full exception text could reach logs and include question or answer content | `/ask` and `/search` log only the exception type; `/search` now shares the concurrency limit | `src/rag/app.py` |
| F7 | Medium | The delete guard missed content lost when a kept file now yields fewer chunks | The guard counts net chunk loss for changed files; a unit test covers it | `src/rag/ingest.py`, `src/tests/test_rag.py` |

The review also corrected several statements in this document: the spoofed-header and token tests now use protected endpoints; the role audit covers resource-scoped assignments; Global Administrators may bypass the assignment requirement; Git limits apply after the clone; one replica per execution is not a global lock; dependency pins are not hash-locked; citation checks are per answer item.

**Confirmed correct by the review:** the Easy Auth schema; the role matrix; local authentication disabled on every service and the registry admin user off; no ingress in locked mode; local mode refused in Azure; the Git hardening; prompt-injection fencing with no model tools; generic 502 errors; Swagger disabled; a non-root container.