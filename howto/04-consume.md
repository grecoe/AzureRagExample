# Consume from an Application

Once deployed and seeded, applications reach the knowledge in one of three ways. All use Microsoft Entra ID tokens; none use keys.

| Pattern | Best for | Needs |
| --- | --- | --- |
| **A. HTTP API** (recommended) | Any language, bots, scripts, other services | Easy Auth mode and an admitted caller identity |
| **B. Search only** | Apps that build their own prompts or show a result list | `POST /search`, or Search Index Data Reader on the search service |
| **C. Python package with Semantic Kernel** | Python apps and agents | Search Index Data Reader and Cognitive Services OpenAI User for the app's identity |

## As Deployed, Only You Are Admitted

The API admits exactly one principal: your user object ID, calling through the Azure CLI client. Three independent checks enforce this:

1. **App registration**: assignment is required, and only you are assigned, so nobody else can obtain a token for the API.
2. **Easy Auth**: `allowedPrincipals` lists only your object ID, and `allowedClientApplications` lists only the Azure CLI.
3. **The app**: it rejects any principal not in `ALLOWED_PRINCIPAL_IDS`.

## Pattern A: Call the API

Python (the same as [../src/client_example.py](../src/client_example.py)):

```python
from azure.identity import AzureCliCredential
import json, urllib.request

token = AzureCliCredential().get_token(f"api://{api_client_id}/.default").token
req = urllib.request.Request(
    f"{api_url}/ask",
    data=json.dumps({"question": "How often do devices send telemetry?"}).encode(),
    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    method="POST",
)
answer = json.loads(urllib.request.urlopen(req, timeout=120).read())
```

C# (.NET):

```csharp
var credential = new Azure.Identity.AzureCliCredential();
var token = await credential.GetTokenAsync(new(new[] { $"api://{apiClientId}/.default" }));
using var http = new HttpClient { BaseAddress = new Uri(apiUrl) };
http.DefaultRequestHeaders.Authorization = new("Bearer", token.Token);
var response = await http.PostAsJsonAsync("/ask", new { question = "How often do devices send telemetry?" });
var answer = await response.Content.ReadFromJsonAsync<JsonElement>();
```

Handle the response as described in [03-query.md](03-query.md#reading-the-answer). Treat `not_found` as a normal result. Retry 502 and 503 with backoff; do not retry 401, 403 or 422.

## Pattern B: Search Only

Call `POST /search` with `{"query": "..."}` for passages without generation. An application that queries Azure AI Search directly needs the Search Index Data Reader role and must embed the query with the same model and dimensions (3,072) as the index.

## Pattern C: Python Package and Semantic Kernel

```python
import asyncio
from rag.answer import RagService
from rag.clients import async_credential, build_kernel, openai_client
from rag.config import load_settings
from rag.search_store import SearchStore


async def main() -> None:
    settings = load_settings()                     # same environment variables as the API
    credential = async_credential(settings)        # managed identity if AZURE_CLIENT_ID is set, else Azure CLI
    client = openai_client(settings, credential)
    try:
        async with SearchStore(settings, credential) as store:
            rag = RagService(settings, build_kernel(settings, client), store)  # registers "retrieval"
            answer = await rag.ask("How often do devices send telemetry?")
            print(answer.to_dict())
    finally:
        await client.close()
        await credential.close()


asyncio.run(main())
```

The kernel now has `retrieval.search_documents`. An agent on the same kernel with automatic function calling (`FunctionChoiceBehavior.Auto()`) can decide when to search. The plugin returns fenced `<source>` blocks labeled `S1..Sn`. Your agent prompt should treat them as untrusted data and cite labels, as `SYSTEM_PROMPT` in `answer.py` does.

Pattern C bypasses the API's checks. The calling identity holds the data roles directly, so grant them only to identities you control.

## Admitting Another Caller (a Deliberate Change)

Adding a caller widens access beyond the single-operator design. Do it only for an identity you own, such as the managed identity of your own Azure-hosted app, and record why.

| Step | Change |
| --- | --- |
| 1. Give the caller its own identity | A managed identity for an Azure-hosted app; never a shared secret |
| 2. Let it get a token | In the API's app registration, add an **application** app role (for example `Rag.Ask`), then assign it to the caller's service principal |
| 3. Admit its client | Add the caller's client (application) ID to `apiAllowedClientApplications` in `main.bicep` |
| 4. Admit its principal | Add its object ID to `allowedPrincipals.identities` and to `ALLOWED_PRINCIPAL_IDS` in `modules/api.bicep` |
| 5. Apply | `azd provision` |

The caller then requests a token with the client-credentials flow for `api://<API_AUTH_CLIENT_ID>/.default`. Review this list whenever the app changes owners, and remove callers you no longer need.

For many callers or per-caller quotas, put Azure API Management in front of the API instead of growing these lists.
