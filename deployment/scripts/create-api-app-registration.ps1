# OPTIONAL. Creates the Entra app registration that protects the API with Easy Auth and assigns
# ONLY the signed-in user to it. Every call goes to Microsoft Graph with an in-memory body, every
# call is checked, and the result is read back and verified before the client ID is saved.
# Next steps: `azd provision` (deploys Easy Auth; ingress stays off), then enable-api-ingress.ps1.
# Your tenant may restrict app registrations; if so, ask a tenant admin to run these steps.
# No client secret or certificate is created: the API only validates tokens.
param(
    [string] $DisplayName
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
& "$PSScriptRoot/check-identity.ps1"

if (Get-AzdValue 'API_AUTH_CLIENT_ID') {
    Write-Host 'API_AUTH_CLIENT_ID is already set. Run ./scripts/enable-api-ingress.ps1 to verify the registration.'
    return
}
if (-not $DisplayName) {
    $environmentName = Get-AzdValue 'AZURE_ENV_NAME'
    if (-not $environmentName) { throw 'Run this from the deployment folder of an initialized azd environment.' }
    $DisplayName = "rag-example-api-$environmentName"
}
$userId = Get-SignedInUserId

$filter = [uri]::EscapeDataString("displayName eq '$($DisplayName.Replace("'", "''"))'")
$found = Invoke-Graph GET "/applications?`$filter=$filter&`$select=appId"
if (Get-ItemCount $found.value) {
    throw "An app registration named '$DisplayName' already exists. Delete it or pass -DisplayName."
}

$scopeId = [guid]::NewGuid().ToString()
$api = @{
    requestedAccessTokenVersion = 2
    oauth2PermissionScopes      = @(@{
            id                      = $scopeId
            value                   = 'user_impersonation'
            type                    = 'User'
            isEnabled               = $true
            adminConsentDisplayName = 'Ask the RAG example API'
            adminConsentDescription = 'Lets the signed-in user call the RAG example API.'
            userConsentDisplayName  = 'Ask the RAG example API'
            userConsentDescription  = 'Lets you call the RAG example API.'
        })
}

$app = $null
try {
    # 1. Single-tenant app with v2 tokens and one delegated scope.
    $app = Invoke-Graph POST '/applications' @{ displayName = $DisplayName; signInAudience = 'AzureADMyOrg'; api = $api }

    # 2. api:// identifier, then pre-authorize only the Azure CLI (the scope must exist first).
    Invoke-Graph PATCH "/applications/$($app.id)" @{ identifierUris = @("api://$($app.appId)") } | Out-Null
    $api.preAuthorizedApplications = @(@{ appId = $script:AzureCliAppId; delegatedPermissionIds = @($scopeId) })
    Invoke-Graph PATCH "/applications/$($app.id)" @{ api = $api } | Out-Null

    # 3. Service principal that requires assignment, then assign only the signed-in user.
    $sp = Invoke-Graph POST '/servicePrincipals' @{ appId = $app.appId; appRoleAssignmentRequired = $true } -RetryOn 400, 404
    Invoke-Graph POST "/servicePrincipals/$($sp.id)/appRoleAssignedTo" @{
        principalId = $userId
        resourceId  = $sp.id
        appRoleId   = '00000000-0000-0000-0000-000000000000'
    } -RetryOn 400, 404 | Out-Null

    # 4. Read back and verify before saving anything to the azd environment.
    $problems = Test-Registration $app.appId $userId
    if ($problems.Count) { $problems | ForEach-Object { Write-Host "  $_" }; throw 'The new registration did not verify.' }

    azd env set API_AUTH_CLIENT_ID $app.appId
    if ($LASTEXITCODE -ne 0) { throw 'Could not save API_AUTH_CLIENT_ID to the azd environment.' }
}
catch {
    if ($app) { Write-Host "Setup stopped. To remove the partial registration, run: az ad app delete --id $($app.appId)" }
    throw
}

Write-Host "Created and verified '$DisplayName'."
Write-Host 'Next: azd provision (Easy Auth is deployed, ingress stays off), then ./scripts/enable-api-ingress.ps1.'