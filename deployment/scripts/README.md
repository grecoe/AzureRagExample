# Scripts

All scripts run in PowerShell 7 as **you**, the signed-in operator. None of them store secrets or write your identity into a file.

| Script | When it runs | What it does |
| --- | --- | --- |
| [check-identity.ps1](check-identity.ps1) | Automatically before `azd provision`; also at the start of the two scripts below | Stops unless azd uses the Azure CLI sign-in (`auth.useAzCliAuth`), the CLI is signed in as a user in the expected tenant and subscription, any `AZURE_PRINCIPAL_ID` is that user, nobody else holds a role in the resource group, and ingress is not open for an unverified client ID. Prints a delete command for each unexpected role assignment. |
| [create-search-index.ps1](create-search-index.ps1) | Automatically after `azd provision` | Creates or updates the index from [../index/rag-docs.index.json](../index/rag-docs.index.json) with your Entra token; retries while roles propagate. Safe to run again. |
| [create-api-app-registration.ps1](create-api-app-registration.ps1) | Manually, once, only if you want network access to the API | Through Microsoft Graph only: creates a single-tenant app registration with no secret, pre-authorizes the Azure CLI, requires assignment, assigns only you, reads it all back and verifies it, then sets `API_AUTH_CLIENT_ID`. Stops if the name already exists. |
| [enable-api-ingress.ps1](enable-api-ingress.ps1) | Manually, after the registration script and one `azd provision` | Verifies the registration and the Easy Auth configuration actually deployed on the API, then sets `API_INGRESS_ENABLED`. Changes nothing if any check fails. Run `azd provision` afterward. |
| [common.ps1](common.ps1) | Dot-sourced by the others | Shared helpers: azd values, the signed-in user, in-memory Microsoft Graph calls with replication retries, and the registration check |

## Running a Hook by Hand

```powershell
cd deployment
pwsh ./scripts/create-search-index.ps1
```

The script reads values from the process environment first, then from `azd env get-value`.

## What the App Registration Script Creates

| Setting | Value | Why |
| --- | --- | --- |
| Sign-in audience | This tenant only | No guests from other tenants |
| Identifier URI | `api://<appId>` | Token audience |
| Access token version | 2 | Matches the v2 issuer Easy Auth validates |
| Delegated scope | `user_impersonation` | Lets the Azure CLI request a token for you |
| Pre-authorized client | Azure CLI (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) | No consent prompt |
| Assignment required | Yes | Only assigned users can get a token at all |
| Assigned users | You | The single operator |
| Credentials | None | The API never signs anyone in; it only validates tokens |
| Owners | You only (checked) | Nobody else can change the registration |

Both scripts check all of these settings: the registration script after it creates the registration, and `enable-api-ingress.ps1` again before ingress opens.
