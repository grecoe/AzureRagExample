# Deployment

Everything needed to deploy the RAG example with the Azure Developer CLI (azd). One `azd up` creates resource group `<resource-group>` in your subscription (`<subscription-id>`), creates the search index, builds the image and deploys the API and the ingestion job.

**Run every azd command from this `deployment/` folder.** That is where `azure.yaml` lives.

| Item | Purpose |
| --- | --- |
| [azure.yaml](azure.yaml) | azd project: two services (`api`, `ingest`) built from `../src`, plus hooks |
| [infra/](infra/README.md) | Bicep: `main.bicep`, parameters and modules |
| [index/](index/README.md) | The search index definition |
| [scripts/](scripts/README.md) | Hook scripts and the optional scripts that register and expose the API |

## Prerequisites

| Tool | Check |
| --- | --- |
| Azure CLI 2.60 or later | `az version` |
| Azure Developer CLI 1.10 or later | `azd version` |
| No local Docker needed | `azd deploy` builds the image in Azure with ACR Tasks (`remoteBuild: true`) |
| PowerShell 7 (`pwsh`) | `pwsh --version`. The hooks run in `pwsh`. |
| Owner or User Access Administrator on the subscription or resource group | Needed to create role assignments |
| Model quota | GlobalStandard quota for `gpt-5.6-sol` and `text-embedding-3-large` in the chosen region |

## Launch with azd

### 1. Sign in once, and make azd use that sign-in

```powershell
az login
az account set --subscription <subscription-id>
azd config set auth.useAzCliAuth true
```

With `auth.useAzCliAuth`, azd deploys as the Azure CLI user, so the identity the preprovision hook checks is the identity that deploys. The hook stops if this setting is missing.

### 2. Create the azd environment

The environment lives in `deployment/.azure/<name>/` and is not checked in. Its name is part of every resource name, so pick the case that matches you:

- **This machine already has it** (`azd env list` shows `rag-poc`): run `azd env select rag-poc` and skip the rest of this step.
- **Work with the existing proof of concept from another machine:** run the commands below with the name `rag-poc`, then `azd env refresh` instead of step 4. Refresh copies the deployment outputs into the environment without changing Azure.
- **Create a separate deployment:** use a different name **and** a different `AZURE_RESOURCE_GROUP_NAME`. A different name in `<resource-group>` adds a second set of resources to that group, and `azd down` from either environment deletes the whole group.

```powershell
cd deployment
azd env new rag-poc
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION eastus2
azd env set AZURE_RESOURCE_GROUP_NAME <resource-group>
```

Do not set `AZURE_PRINCIPAL_ID`. azd resolves your Entra object ID from the signed-in user during each provision and does not store it. That user is the **only** human identity granted access. If a value is present, the preprovision hook stops unless it matches you.

### 3. Optional settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `AZURE_RESOURCE_GROUP_NAME` | `rg-rag-poc` | Resource group to create or reuse |
| `AZURE_SEARCH_LOCATION` | empty (uses `AZURE_LOCATION`) | Region for Azure AI Search only. Set it when the main region has no Search capacity (`InsufficientResourcesAvailable`). The proof of concept uses `centralus`. |
| `API_AUTH_CLIENT_ID` | empty | Empty: the API has **no ingress** (locked). Set by the registration script. See step 6. |
| `API_INGRESS_ENABLED` | `false` | Set only by [enable-api-ingress.ps1](scripts/enable-api-ingress.ps1) after it verifies the deployed Easy Auth. See step 6. |
| `ENABLE_INGEST_SCHEDULE` | `false` | `true` runs the ingestion job daily at 06:00 UTC |
| `RAG_INDEX_NAME` | `rag-docs` | Change it for a blue/green rebuild |
| `RAG_SOURCE_KIND` | `local` | `local` indexes the `sample-data` baked into the image; `git` clones `RAG_GIT_URL` on every run |
| `RAG_GIT_URL`, `RAG_GIT_REF` | empty, `main` | Public HTTPS repository and branch or tag |
| `RAG_GIT_INCLUDE` | `**/*.md` | Files to index |
| `RAG_GIT_ALLOWED_HOSTS` | `github.com` | Hosts the job may clone from |

Other Bicep parameters (model versions, capacity, IP allow-list) have defaults in [infra/main.bicep](infra/main.bicep). Add them to [infra/main.parameters.json](infra/main.parameters.json) to set them from azd.

### 4. Preview, then deploy

```powershell
azd provision --preview   # shows what will be created; changes nothing
azd up                    # provision + create index + build + deploy
```

`azd up` runs these steps in order:

1. **preprovision hook** ([check-identity.ps1](scripts/check-identity.ps1)): stops unless azd uses the Azure CLI sign-in, that sign-in is a user in the expected tenant and subscription, any `AZURE_PRINCIPAL_ID` is that user, and nobody else holds a role in the resource group. For each unexpected role assignment, it prints the delete command.
2. **provision**: runs [infra/main.bicep](infra/main.bicep) at subscription scope.
3. **postprovision hook** ([create-search-index.ps1](scripts/create-search-index.ps1)): creates or updates the index as you.
4. **deploy**: uploads the `azure-rag-example` folder (filtered by [../.dockerignore](../.dockerignore)) to ACR. ACR Tasks then builds `../src/Dockerfile` in Azure and pushes the image to the same registry. azd updates both the API and the job. Build logs stream to your terminal.

### 5. Seed the index

The index is empty after deployment. Start the job once:

```powershell
$rg  = azd env get-value AZURE_RESOURCE_GROUP
$job = azd env get-value INGEST_JOB_NAME
az containerapp job start --name $job --resource-group $rg
az containerapp job execution list --name $job --resource-group $rg -o table
```

The job runs in `update` mode. On an empty index, that indexes everything. For other options, including seeding from your workstation, see [howto/01-seed.md](../howto/01-seed.md).

### 6. Choose how the API is reached

| Mode | How to get it | Who can call the API |
| --- | --- | --- |
| **Locked** (default) | Leave `API_AUTH_CLIENT_ID` empty | Nobody over the network; the container app has no ingress. Query from your workstation instead ([howto/03-query.md](../howto/03-query.md)). |
| **Easy Auth** | Register, provision, verify, provision (below) | Only your identity, only through the Azure CLI client, only with a valid token for this API |

Ingress turns on only after the deployed Easy Auth configuration is checked:

```powershell
pwsh ./scripts/create-api-app-registration.ps1   # creates, reads back and verifies the registration
azd provision                                    # deploys Easy Auth; ingress stays off
pwsh ./scripts/enable-api-ingress.ps1            # verifies registration and deployed Easy Auth; sets API_INGRESS_ENABLED
azd provision                                    # turns on HTTPS ingress
azd env get-value API_URL
```

To lock the API again, run `azd env set API_INGRESS_ENABLED false`, then `azd provision`. If `API_AUTH_CLIENT_ID` changes after verification, the preprovision hook stops until you lock the API and verify again.

Your tenant may not let you create app registrations. If so, ask a tenant admin to run the script, or stay in locked mode.

### 7. Turn on the daily refresh (after checking the seed)

```powershell
azd env set ENABLE_INGEST_SCHEDULE true
azd provision
```

### 8. Redeploy code only

```powershell
azd deploy          # both services
azd deploy ingest   # just the job
```

### 9. Remove everything

```powershell
azd down --purge
```

`--purge` also purges the soft-deleted AI Services account so its name can be reused. Delete the optional app registration separately with `az ad app delete --id $(azd env get-value API_AUTH_CLIENT_ID)`.

## Outputs

azd stores these in the environment. Read them with `azd env get-value <name>`.

| Output | Example use |
| --- | --- |
| `AZURE_RESOURCE_GROUP` | `az` commands |
| `AZURE_SEARCH_ENDPOINT`, `AZURE_SEARCH_INDEX` | Local runs and the index hook |
| `AZURE_OPENAI_ENDPOINT` and the deployment names | Local runs |
| `AZURE_OPENAI_EMBEDDING_DIMENSIONS` | Index creation |
| `API_URL` | Calling the API (empty while locked) |
| `INGEST_JOB_NAME` | Starting the job |
| `AZURE_APPLICATION_INSIGHTS_NAME` | Querying custom events ([05-operate.md](../howto/05-operate.md#custom-events)) |
| `AZURE_CONTAINER_REGISTRY_ENDPOINT` | Used by azd to push images |

## Troubleshooting Deployment

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `azd must use the Azure CLI sign-in` | `auth.useAzCliAuth` is not set | `azd config set auth.useAzCliAuth true` |
| `AZURE_PRINCIPAL_ID does not match` | A stale value in the azd environment | Remove the `AZURE_PRINCIPAL_ID` line from `.azure/<env>/.env` |
| `Found N role assignment(s) ... for someone other than you` | A previous operator or another person still has access | Run the printed `az role assignment delete` commands, then retry |
| `Verification failed; ingress was not enabled` | The registration or the deployed Easy Auth differs from what is expected | Fix each listed item. Never set `API_INGRESS_ENABLED` by hand. |
| `InsufficientQuota` or model not found | No quota for the model in this region | Change `AZURE_LOCATION`, lower capacity, or change the model parameters |
| Index hook fails six times | Role assignment still propagating, or you lack Search Service Contributor | Wait five minutes, then run `pwsh ./scripts/create-search-index.ps1` |
| `RequestDisallowedByPolicy` | Subscription or tenant policy | Read the policy name in the error; adjust the Bicep or request an exemption. A policy that requires VNet injection is already handled by [network.bicep](infra/modules/network.bicep). |
| `InsufficientResourcesAvailable` for Search | No Search capacity in the region | `azd env set AZURE_SEARCH_LOCATION <region>` (for example `centralus`), then `azd up` again |
| Provisioning sits on the Container Apps environment | First VNet-injected environment takes about 15 minutes | Wait; this is expected |
| Image pull failure on first deploy | AcrPull not yet effective | Run `azd deploy` again after a few minutes |

More: [howto/06-troubleshoot.md](../howto/06-troubleshoot.md).
