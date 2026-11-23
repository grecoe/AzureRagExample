# azd postprovision hook. Creates or updates the search index as the signed-in operator.
# Uses an Entra token (search keys are disabled). Safe to run again: PUT is create-or-update.
# Changing vector dimensions or field types requires a new index name (blue/green), not an update.
$ErrorActionPreference = 'Stop'

function Get-Setting([string] $Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value) {
        $value = azd env get-value $Name 2>$null
        if ($LASTEXITCODE -ne 0) { $value = '' }
    }
    $value = "$value".Trim()
    if (-not $value) { throw "$Name is not set. Run azd provision first." }
    return $value
}

$endpoint = (Get-Setting 'AZURE_SEARCH_ENDPOINT').TrimEnd('/')
$indexName = Get-Setting 'AZURE_SEARCH_INDEX'
$dimensions = [int](Get-Setting 'AZURE_OPENAI_EMBEDDING_DIMENSIONS')

if ($endpoint -notmatch '^https://[a-z0-9-]+\.search\.windows\.net$') { throw 'AZURE_SEARCH_ENDPOINT is not a valid search endpoint.' }
if ($indexName -notmatch '^[a-z0-9][a-z0-9-]{0,127}$') { throw 'AZURE_SEARCH_INDEX must be lowercase letters, digits, and hyphens.' }

$definitionPath = Join-Path $PSScriptRoot '..\index\rag-docs.index.json'
$definition = Get-Content $definitionPath -Raw | ConvertFrom-Json
$definition.name = $indexName
($definition.fields | Where-Object name -eq 'content_vector').dimensions = $dimensions

$body = Join-Path ([IO.Path]::GetTempPath()) "rag-index-$([guid]::NewGuid()).json"
$definition | ConvertTo-Json -Depth 20 | Set-Content -Path $body -Encoding utf8
try {
    # Role assignments can take several minutes to propagate after provisioning.
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        az rest --method put `
            --url "$endpoint/indexes/$($indexName)?api-version=2025-09-01" `
            --resource 'https://search.azure.com' `
            --headers 'Content-Type=application/json' `
            --body "@$body" --output none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Search index '$indexName' is ready."
            return
        }
        Write-Host "Index request failed (attempt $attempt of 6). Waiting for role assignments to propagate..."
        Start-Sleep -Seconds (20 * $attempt)
    }
    throw "Could not create index '$indexName'. Confirm you hold Search Service Contributor on the search service."
}
finally {
    Remove-Item $body -ErrorAction SilentlyContinue
}
