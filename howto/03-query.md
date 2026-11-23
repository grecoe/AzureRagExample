# Ask Questions

There are two ways to query, depending on whether the API is locked (the default) or exposed through Easy Auth.

## From Your Workstation (Works in Either Mode)

Run the API locally with your own identity. It listens on `127.0.0.1` only. Set-up steps are in [../src/README.md](../src/README.md#run-locally).

```powershell
cd src
python main.py
```

In a second terminal:

```powershell
$body = @{ question = 'How often do devices send telemetry?'; mode = 'generative' } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/ask -ContentType 'application/json' -Body $body |
    ConvertTo-Json -Depth 5
```

Interactive API docs are at `http://127.0.0.1:8080/docs` in local mode only.

## Through the Deployed API (Easy Auth Mode)

Needs the app registration ([../deployment/README.md](../deployment/README.md#6-choose-how-the-api-is-reached)).

```powershell
cd deployment
$url      = azd env get-value API_URL
$clientId = azd env get-value API_AUTH_CLIENT_ID
$token    = az account get-access-token --scope "api://$clientId/.default" --query accessToken -o tsv

$body = @{ question = 'How often do devices send telemetry?' } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri "$url/ask" -ContentType 'application/json' `
    -Headers @{ Authorization = "Bearer $token" } -Body $body
```

Or run the Python sample: `python ../src/client_example.py $url $clientId "How often do devices send telemetry?"`.

The first call after an idle period can take several seconds, because the app scales to zero.

## Endpoints

| Endpoint | Body | Returns |
| --- | --- | --- |
| `POST /ask` | `{"question": "...", "mode": "generative"}` | A cited answer, `not_found`, or passages only |
| `POST /ask` | `{"question": "...", "mode": "extractive"}` | Top passages with no generated text; no language-model cost |
| `POST /search` | `{"query": "..."}` | Top passages, with no relevance gate |
| `GET /healthz` | — | `{"status": "ok"}`. Behind Easy Auth it also needs a token. |

Questions longer than `RAG_MAX_QUESTION_CHARS` (1,000) return 422.

## Reading the Answer

| `status` | Meaning | What to show the user |
| --- | --- | --- |
| `answered` | Every sentence cites passages (`[S1]`), and `passages` holds only the cited ones | The answer with links built from each `locator` |
| `not_found` | Retrieval was too weak, the model said the sources do not answer, or its output failed the citation check | "Not found in the documents", plus the `passages` as "possibly related" |
| `extractive` | You asked for passages only | The passages |

A citation shows **where** a sentence came from; it does not prove the passage supports it. Spot-check answers that matter.

## Tuning Relevance

| Symptom | Adjust |
| --- | --- |
| Too many `not_found` for questions the documents do answer | Lower `RAG_MIN_RERANKER_SCORE` (for example 1.0), or raise `RAG_TOP_K` |
| Answers drawn from loosely related passages | Raise `RAG_MIN_RERANKER_SCORE` (for example 2.0) |
| Right file, wrong section | Check headings in the source; chunking follows them |

To try a value locally, set the variable and restart `python main.py`. To change the deployed value, add it to the API's `env` list in `deployment/infra/modules/api.bicep` and run `azd provision`.

To measure the effect, check the reranker scores for 20–30 questions with known answers. API responses do not include scores, so query the index directly (keyword plus semantic ranking; your account has the reader role):

```powershell
cd deployment
$endpoint = azd env get-value AZURE_SEARCH_ENDPOINT
$index    = azd env get-value AZURE_SEARCH_INDEX
$query = @{ search = 'How often do devices send telemetry?'; queryType = 'semantic'
            semanticConfiguration = 'default'; select = 'title,locator'; top = 5 } | ConvertTo-Json
$file = New-TemporaryFile; Set-Content $file $query
$result = az rest --method post --resource https://search.azure.com --headers 'Content-Type=application/json' `
    --url "$endpoint/indexes/$index/docs/search?api-version=2025-09-01" --body "@$file" | ConvertFrom-Json
$result.value | Select-Object @{ n = 'score'; e = { $_.'@search.rerankerScore' } }, title
Remove-Item $file
```

Scores run from 0 to 4. The API adds vector search to this query, so its scores are similar but not identical.
