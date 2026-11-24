# Infrastructure (Bicep)

[main.bicep](main.bicep) is the entry point. It runs at **subscription scope**, creates the resource group, and calls one module per concern. azd fills in its parameters from [main.parameters.json](main.parameters.json), which maps azd environment values to Bicep parameters.

## Naming

Every resource name ends with a token: `uniqueString(subscription, resource group, environment)`. The same environment always produces the same names, and different environments never collide.

| Prefix | Resource |
| --- | --- |
| `srch-` | Azure AI Search |
| `ai-` | Azure AI Foundry (AIServices) account; also its custom subdomain |
| `cr` | Container Registry (no hyphen allowed) |
| `log-`, `appi-` | Log Analytics, Application Insights |
| `cae-` | Container Apps environment |
| `ca-api-`, `caj-ingest-` | API Container App, ingestion Container Apps Job |
| `id-api-`, `id-ingest-` | User-assigned managed identities |
| `vnet-`, `nsg-cae-` | Virtual network with a private subnet (no default outbound access) delegated to Container Apps, and its NSG |

## Parameters

| Parameter | Default | Notes |
| --- | --- | --- |
| `environmentName` | from azd | Required |
| `location` | `eastus2` | Must offer both models |
| `searchLocation` | empty (uses `location`) | Region for Azure AI Search only, from `AZURE_SEARCH_LOCATION` |
| `resourceGroupName` | `rg-rag-poc` | |
| `principalId` | from `AZURE_PRINCIPAL_ID`, which azd resolves from the signed-in user at provision time | The single human operator |
| `principalType` | `User` | Restricted to `User` |
| `apiAuthClientId` | empty | Empty: no Easy Auth and no API ingress |
| `apiIngressEnabled` | `false` | Ingress opens only when this is `true` **and** `apiAuthClientId` is set. Set through `enable-api-ingress.ps1`, never in the same deployment that first creates Easy Auth. |
| `apiAllowedClientApplications` | Azure CLI | Client apps allowed to obtain tokens for the API |
| `apiAllowedIpRanges` | empty | Optional CIDR allow-list on ingress |
| `enableIngestSchedule`, `ingestCron` | `false`, `0 6 * * *` | Daily refresh |
| `searchIndexName` | `rag-docs` | Blue/green rebuilds change this |
| `embedding*`, `chat*` | `text-embedding-3-large` v1 at 3,072 dimensions; `gpt-5.6-sol` `2026-07-09` | Capacity is thousands of tokens per minute |
| `sourceKind`, `git*` | `local` | Set to `git` with an HTTPS URL on an allow-listed host |
| `apiExists`, `ingestExists` | set by azd | Keep the deployed image on re-provision |

## Outbound Traffic

The Container Apps subnet is private (`defaultOutboundAccess: false`), as SFI-NS2.6.1 requires. The environment's platform-managed load balancer and static public IP carry outbound calls to Search, AI Services, the registry, Application Insights and Microsoft Entra ID. If calls fail after this change, attach a Standard NAT gateway to the subnet; Container Apps does not support the StandardV2 SKU.

For an existing deployment, run `azd provision`. If Azure rejects the subnet change while the environment exists, redeploy with `azd down --purge` and `azd up`. Then run the checks in [../../howto/07-test-search.md](../../howto/07-test-search.md).

## Validate Without Deploying

```powershell
az bicep build --file main.bicep --stdout > $null
azd provision --preview
```

The first command checks syntax and types locally. The second shows what Azure would create, which needs a signed-in session but changes nothing.

Module details: [modules/README.md](modules/README.md).
