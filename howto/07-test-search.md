# Test Search End to End

Follow this guide to confirm that the system answers questions correctly and that only admitted callers get in. Run the levels in order. Each level builds on the one before it, and you can stop at any level that proves what you need.

| Level | Proves | Needs |
| --- | --- | --- |
| [1. Unit tests](#level-1-unit-tests) | Chunking, grounding, ingest planning and authorization logic | Python only; no Azure |
| [2. The index has content](#level-2-check-the-index-has-content) | Seeding worked | Deployed and seeded |
| [3. Local API](#level-3-test-through-a-local-api) | Retrieval and answers work with the deployed index and models | Your Azure CLI sign-in |
| [4. Deployed API](#level-4-test-the-deployed-api) | The deployed API answers over HTTPS for you | Easy Auth mode |
| [5. Access control](#level-5-confirm-access-is-refused) | Callers without a valid token are refused | Easy Auth mode |
| [6. Another application](#level-6-test-from-another-application) | An application you own can call the API | A deliberate access change |
| [7. Telemetry](#level-7-confirm-the-calls-were-recorded) | Calls are recorded for monitoring | Any level from 3 onward |

All commands assume PowerShell 7, a signed-in Azure CLI (`az login`) as the operator, and that you start in the repository root.

## Test Questions

These questions match the included [sample data](../sample-data/README.md). If you indexed your own documents, write 5–10 questions with answers you already know, plus at least one question the documents cannot answer.

| Question | Expected `status` | Expected answer contains | Source file |
| --- | --- | --- | --- |
| How often does the edge agent send batches? | `answered` | 30 seconds | `fleet-telemetry-overview.md`, `onboarding.md` |
| How long is raw telemetry kept? | `answered` | 90 days | `faq.md`, `fleet-telemetry-overview.md` |
| Which schema version should new device types use? | `answered` | Schema version 4 | `faq.md`, `onboarding.md` |
| Why are batches rejected with HTTP 401? | `answered` | Expired or revoked certificate; clock skew over five minutes | `troubleshooting.md` |
| What is the cafeteria menu on Friday? | `not_found` | — | None; checks that the system refuses rather than guesses |

A citation shows where a sentence came from. It does not prove the passage supports the sentence, so read the cited passage for each answer.

## Level 1: Unit Tests

```powershell
cd src
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python -m unittest discover -s tests -t .
```

Expect all tests to pass. They cover the logic only; the levels below check the Azure services. Test coverage is listed in [../src/tests/README.md](../src/tests/README.md).

## Level 2: Check the Index Has Content

```powershell
cd deployment
$endpoint = azd env get-value AZURE_SEARCH_ENDPOINT
$index    = azd env get-value AZURE_SEARCH_INDEX
az rest --method get --resource https://search.azure.com `
    --url "$endpoint/indexes/$index/docs/`$count?api-version=2025-09-01"
```

Expect a number greater than zero. If it is zero, seed the index first ([01-seed.md](01-seed.md)).

## Level 3: Test Through a Local API

This level works whether the API is locked (the default) or exposed. The local API uses your own sign-in, which already holds the data roles.

**Terminal 1: start the API.** Set the environment variables as described in [../src/README.md](../src/README.md#run-locally), then run:

```powershell
cd src
.\.venv\Scripts\Activate.ps1
$env:AUTH_MODE = 'local'
python main.py
```

The API listens on `http://127.0.0.1:8080` only. Interactive docs are at `http://127.0.0.1:8080/docs`, where you can try each endpoint from a browser.

**Terminal 2: send requests.**

```powershell
$base = 'http://127.0.0.1:8080'

function Ask([string] $question, [string] $mode = 'generative') {
    $body = @{ question = $question; mode = $mode } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$base/ask" -ContentType 'application/json' -Body $body
}

# Health
Invoke-RestMethod "$base/healthz"

# Answer with citations
$r = Ask 'How often does the edge agent send batches?'
$r.status; $r.answer
$r.passages | Select-Object label, title, locator

# Passages only (no language-model cost)
(Ask 'How long is raw telemetry kept?' 'extractive').passages | Select-Object label, title

# Search only (no relevance gate, no answer)
$body = @{ query = 'certificate expired' } | ConvertTo-Json
(Invoke-RestMethod -Method Post -Uri "$base/search" -ContentType 'application/json' -Body $body).passages |
    Select-Object label, title, locator

# Refusal: expect not_found
(Ask 'What is the cafeteria menu on Friday?').status
```

To run every test question at once:

```powershell
$cases = @(
    @{ q = 'How often does the edge agent send batches?';        expect = 'answered' }
    @{ q = 'How long is raw telemetry kept?';                     expect = 'answered' }
    @{ q = 'Which schema version should new device types use?';   expect = 'answered' }
    @{ q = 'Why are batches rejected with HTTP 401?';             expect = 'answered' }
    @{ q = 'What is the cafeteria menu on Friday?';               expect = 'not_found' }
)
$cases | ForEach-Object {
    $r = Ask $_.q
    [pscustomobject]@{ Pass = $r.status -eq $_.expect; Status = $r.status; Question = $_.q; Answer = $r.answer }
} | Format-Table -Wrap
```

Check that every row passes and that each answer contains the expected value from the [test questions](#test-questions).

**Input checks.** Each of these should return HTTP 422:

```powershell
$long = 'x' * 1001
foreach ($q in @('hi', $long)) {
    try { Ask $q | Out-Null; 'Unexpected success' }
    catch { "HTTP $($_.Exception.Response.StatusCode.value__)" }
}
```

A question shorter than 3 characters fails validation, and one longer than `RAG_MAX_QUESTION_CHARS` (1,000 by default) is refused.

## Level 4: Test the Deployed API

The API is locked by default and has no network endpoint. To expose it to yourself only, follow [../deployment/README.md](../deployment/README.md#6-choose-how-the-api-is-reached):

```powershell
cd deployment
pwsh ./scripts/create-api-app-registration.ps1
azd provision
pwsh ./scripts/enable-api-ingress.ps1
azd provision
```

Then call it with a token for the API:

```powershell
cd deployment
$base     = azd env get-value API_URL
$clientId = azd env get-value API_AUTH_CLIENT_ID
$token    = az account get-access-token --scope "api://$clientId/.default" --query accessToken -o tsv
$headers  = @{ Authorization = "Bearer $token" }

$body = @{ question = 'How often does the edge agent send batches?' } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri "$base/ask" -ContentType 'application/json' -Headers $headers -Body $body
```

Or use the Python sample:

```powershell
python ../src/client_example.py $base $clientId "How often does the edge agent send batches?"
```

To reuse the Level 3 checks, set `$base` to `API_URL` and add `-Headers $headers` to each `Invoke-RestMethod` call. Behind Easy Auth, `/healthz` also needs the token, and `/docs` is not available.

The first call after an idle period can take several seconds, because the API scales to zero. Retry HTTP 502 or 503 once before investigating.

## Level 5: Confirm Access Is Refused

Run these against the deployed API from Level 4. Each should fail with HTTP 401 or 403.

```powershell
function Status([hashtable] $h) {
    $body = @{ question = 'How long is raw telemetry kept?' } | ConvertTo-Json
    try { Invoke-RestMethod -Method Post -Uri "$base/ask" -ContentType 'application/json' -Headers $h -Body $body | Out-Null; 'Unexpected success' }
    catch { "HTTP $($_.Exception.Response.StatusCode.value__)" }
}

Status @{}                                          # no token
Status @{ Authorization = 'Bearer not-a-token' }    # invalid token
$armToken = az account get-access-token --query accessToken -o tsv
Status @{ Authorization = "Bearer $armToken" }      # valid token for a different audience
```

To test a different identity, sign in as another user in a separate session and request a token for the API. Because assignment is required on the app registration, Microsoft Entra ID should refuse to issue the token. If a token is issued, Easy Auth and the app's `ALLOWED_PRINCIPAL_IDS` check should still refuse the call.

## Level 6: Test from Another Application

As deployed, only you are admitted. Letting another application call the API widens access, so do it only for an identity you own and record why. The steps are in [04-consume.md](04-consume.md#admitting-another-caller-a-deliberate-change). In summary:

1. Give the application a managed identity.
2. In the API's app registration, add an application app role, such as `Rag.Ask`, and assign it to the identity.
3. Add the application's client ID to `apiAllowedClientApplications` in `deployment/infra/main.bicep`.
4. Add its object ID to `allowedPrincipals.identities` and `ALLOWED_PRINCIPAL_IDS` in `deployment/infra/modules/api.bicep`.
5. Run `azd provision`.

In the application, request a token for `api://<API_AUTH_CLIENT_ID>/.default` with its managed identity, and call the same endpoints. For example, in Python:

```python
from azure.identity import ManagedIdentityCredential
import json, urllib.request

token = ManagedIdentityCredential(client_id=app_identity_client_id).get_token(
    f"api://{api_client_id}/.default").token
req = urllib.request.Request(
    f"{api_url}/ask",
    data=json.dumps({"question": "How often does the edge agent send batches?"}).encode(),
    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    method="POST",
)
print(json.loads(urllib.request.urlopen(req, timeout=120).read())["status"])
```

Expect `answered`. Then remove the role assignment, or the ID from either list, run `azd provision`, and confirm the same call now fails with 401 or 403.

Two other ways an application can search, each covered in [04-consume.md](04-consume.md):

- **Query Azure AI Search directly.** The identity needs the Search Index Data Reader role, and it must embed queries with `text-embedding-3-large` at 3,072 dimensions to match the index.
- **Import the Python package with Semantic Kernel.** This skips the API's access checks, because the identity holds the data roles directly. Grant those roles only to identities you control.

## Level 7: Confirm the Calls Were Recorded

Every `POST /ask` and `POST /search` that reaches the app writes a `RagApiCall` event. Calls rejected by Easy Auth before they reach the app do not. Events can take a few minutes to appear.

```powershell
cd deployment
$rg   = azd env get-value AZURE_RESOURCE_GROUP
$appi = azd env get-value AZURE_APPLICATION_INSIGHTS_NAME
az monitor app-insights query --app $appi --resource-group $rg --analytics-query @'
customEvents
| where timestamp > ago(1h) and name == "RagApiCall"
| project timestamp, operation = tostring(customDimensions.operation), status = tostring(customDimensions.status),
          http_status = tostring(customDimensions.http_status), answer_status = tostring(customDimensions.answer_status),
          duration_ms = todouble(customMeasurements.duration_ms)
| order by timestamp desc
'@
```

Expect one row for each call you made, with matching statuses. Events never contain question or answer text. For dashboards and alerts, see [05-operate.md](05-operate.md). Local runs send telemetry only when `APPLICATIONINSIGHTS_CONNECTION_STRING` is set.

## If a Check Fails

| Symptom | Next step |
| --- | --- |
| Unit tests fail | Reinstall from `requirements.txt` in a fresh virtual environment; the versions are pinned and tested together |
| Index count is zero | Seed the index ([01-seed.md](01-seed.md)) |
| Questions the documents answer return `not_found` | Tune `RAG_MIN_RERANKER_SCORE` or `RAG_TOP_K` ([03-query.md](03-query.md#tuning-relevance)) |
| HTTP 401 or 403 with your own token | Confirm the token's audience is `api://<API_AUTH_CLIENT_ID>` and that you are assigned to the app registration ([06-troubleshoot.md](06-troubleshoot.md)) |
| HTTP 502 | An upstream call to Azure AI Search or Azure OpenAI failed; check `AppExceptions` and `ContainerAppConsoleLogs` ([06-troubleshoot.md](06-troubleshoot.md)) |
| No `RagApiCall` events | Wait a few minutes, then confirm the call reached the app rather than being refused by Easy Auth |
