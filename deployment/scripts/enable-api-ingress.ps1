# OPTIONAL, second half of exposing the API. Run after create-api-app-registration.ps1 and one
# `azd provision`. It verifies the app registration and the Easy Auth configuration that is
# actually deployed, and only then sets API_INGRESS_ENABLED. Run `azd provision` afterward to
# turn on ingress. Safe to run again: it changes nothing unless every check passes.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
& "$PSScriptRoot/check-identity.ps1"

$userId = Get-SignedInUserId
$clientId = Get-AzdValue 'API_AUTH_CLIENT_ID'
if (-not $clientId) { throw 'API_AUTH_CLIENT_ID is not set. Run ./scripts/create-api-app-registration.ps1 first.' }
$subscription = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
$resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
$apiName = Get-AzdValue 'API_NAME'
if (-not $resourceGroup -or -not $apiName) { throw 'The API is not provisioned yet. Run: azd provision' }
$tenant = (az account show --query tenantId -o tsv 2>$null)
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI is not signed in. Run: az login' }

$problems = Test-Registration $clientId $userId

function Get-Arm([string] $Path) {
    $json = az rest --method get --url "$Path`?api-version=2024-03-01" -o json 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $value = $json | ConvertFrom-Json
    if ($value.properties) { return $value.properties }
    return $value
}
function Test-Exactly($Actual, [string[]] $Expected) {
    $left = @($Actual | Where-Object { $null -ne $_ } | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object)
    $right = @($Expected | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
    return ($left -join ',') -eq ($right -join ',')
}

$appPath = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.App/containerApps/$apiName"
$auth = Get-Arm "$appPath/authConfigs/current"
if (-not $auth) {
    $problems.Add('Easy Auth is not deployed. Run azd provision with API_AUTH_CLIENT_ID set, then run this again.')
}
else {
    $aad = $auth.identityProviders.azureActiveDirectory
    if (-not $auth.platform.enabled) { $problems.Add('Easy Auth is not enabled.') }
    if ($auth.globalValidation.unauthenticatedClientAction -ne 'Return401') { $problems.Add('Unauthenticated requests are not rejected with 401.') }
    if (-not $aad.enabled) { $problems.Add('The Microsoft Entra ID provider is not enabled.') }
    if ($aad.registration.clientId -ne $clientId) { $problems.Add('Easy Auth uses a different client ID.') }
    if ("$($aad.registration.openIdIssuer)" -notlike "*/$("$tenant".Trim())/v2.0") { $problems.Add('Easy Auth trusts a different token issuer.') }
    if (-not (Test-Exactly $aad.validation.allowedAudiences @($clientId, "api://$clientId"))) { $problems.Add('Easy Auth accepts unexpected audiences.') }
    if (-not (Test-Exactly $aad.validation.jwtClaimChecks.allowedClientApplications @($script:AzureCliAppId))) { $problems.Add('Easy Auth allows client applications other than the Azure CLI.') }
    if (-not (Test-Exactly $aad.validation.defaultAuthorizationPolicy.allowedPrincipals.identities @($userId))) { $problems.Add('Easy Auth admits principals other than you.') }
}

$containerApp = Get-Arm $appPath
$environment = @($containerApp.template.containers | Where-Object name -eq 'api' | ForEach-Object env)
$setting = @{}
foreach ($item in $environment) { $setting[$item.name] = $item.value }
if ($setting['AUTH_MODE'] -ne 'easyauth') { $problems.Add('The API container is not running in easyauth mode.') }
if (-not (Test-Exactly ("$($setting['ALLOWED_PRINCIPAL_IDS'])".Split(',') | Where-Object { $_ }) @($userId))) {
    $problems.Add('The API container admits principals other than you.')
}

if ($problems.Count) {
    $problems | ForEach-Object { Write-Host "  $_" }
    throw 'Verification failed; ingress was not enabled.'
}

azd env set API_INGRESS_VERIFIED_CLIENT_ID $clientId
if ($LASTEXITCODE -ne 0) { throw 'Could not save API_INGRESS_VERIFIED_CLIENT_ID to the azd environment.' }
azd env set API_INGRESS_ENABLED true
if ($LASTEXITCODE -ne 0) { throw 'Could not save API_INGRESS_ENABLED to the azd environment.' }
Write-Host 'Verified. Run azd provision to turn on HTTPS ingress behind Easy Auth.'