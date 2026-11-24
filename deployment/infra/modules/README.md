# Bicep Modules

Each module owns one concern. Every resource that supports it has local (key) authentication turned off.

| Module | Creates | Security-relevant settings |
| --- | --- | --- |
| [identity.bicep](identity.bicep) | `id-api-*`, `id-ingest-*` | Separate identities so the API can only read and the job can only write data |
| [monitoring.bicep](monitoring.bicep) | Log Analytics (30-day retention), Application Insights | `DisableLocalAuth: true`: telemetry needs an Entra token |
| [search.bicep](search.bicep) | AI Search, Basic, 1 replica, 1 partition | `disableLocalAuth: true`, semantic ranker `free`, diagnostics to Log Analytics |
| [ai.bicep](ai.bicep) | AIServices account; embedding and chat deployments | `disableLocalAuth: true`, custom subdomain (required for Entra auth), diagnostics |
| [acr.bicep](acr.bicep) | Container Registry, Basic | Admin user disabled |
| [roles.bicep](roles.bicep) | 12 role assignments | Each scoped to one resource, never the resource group |
| [network.bicep](network.bicep) | VNet `10.40.0.0/16`, subnet `snet-cae` `10.40.0.0/23` delegated to `Microsoft.App/environments`, NSG | Required where tenant policy enforces VNet injection; NSG has default rules only, so no extra inbound ports; private subnet (`defaultOutboundAccess: false`, SFI-NS2.6.1), so outbound traffic uses the environment's managed load balancer |
| [containerapps-env.bicep](containerapps-env.bicep) | Container Apps environment (Consumption workload profile), VNet-injected, `internal: false` | Logs through diagnostic settings, so no workspace shared key is stored; public ingress is possible only when the API's ingress is enabled behind Easy Auth |
| [fetch-image.bicep](fetch-image.bicep) | Nothing | Reads the current image so re-provisioning does not revert to the placeholder |
| [api.bicep](api.bicep) | API Container App; Easy Auth configuration | Easy Auth only when `authClientId` is set; ingress only when `ingressEnabled` is also true; Easy Auth `Return401`; allowed principal = operator only; allowed client app = Azure CLI; no client secret |
| [ingest-job.bicep](ingest-job.bicep) | Ingestion Container Apps Job | No ingress; parallelism 1; 1-hour timeout; no retries (a rerun is safe) |

## Role Assignments

| Principal | Search | AI Services | Registry | App Insights |
| --- | --- | --- | --- | --- |
| `id-api` | Search Index Data Reader | Cognitive Services OpenAI User | AcrPull | Monitoring Metrics Publisher |
| `id-ingest` | Search Index Data Contributor | Cognitive Services OpenAI User | AcrPull | Monitoring Metrics Publisher |
| Operator (you) | Search Service Contributor, Search Index Data Contributor | Cognitive Services OpenAI User | AcrPush, Container Registry Tasks Contributor (remote build) | — |

The API and job modules depend on `roles`, so AcrPull exists before either tries to pull an image.

Role assignment names are deterministic, built from `guid(resource, principal, role)`, so re-provisioning never creates duplicates.
