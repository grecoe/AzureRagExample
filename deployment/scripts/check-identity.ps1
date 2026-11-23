# azd preprovision hook (also run by the other scripts). Stops before any change unless:
#   1. azd deploys with the same Azure CLI sign-in that this script checks;
#   2. that sign-in is a user, in the expected tenant and subscription;
#   3. any AZURE_PRINCIPAL_ID azd resolved is that same user;
#   4. no other person or group still holds a role in the resource group (for example, a
#      previous operator); and
#   5. API ingress is not about to open behind an auth configuration that was never verified.
# Nothing is written to disk. Commands to remove stale grants are printed to the console only.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"

# 1. Without this setting azd can deploy as a different identity than the Azure CLI.
$useCli = azd config get auth.useAzCliAuth 2>$null
if ($LASTEXITCODE -ne 0 -or "$useCli".Trim().Trim('"') -ne 'true') {
    throw 'azd must use the Azure CLI sign-in. Run: azd config set auth.useAzCliAuth true'
}

# 2. User, tenant and subscription.
$accountJson = az account show --query '{sub:id, tenant:tenantId, type:user.type}' -o json 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI is not signed in. Run: az login' }
$account = $accountJson | ConvertFrom-Json
if ($account.type -ne 'user') { throw 'Azure CLI must be signed in as a user, not a service principal.' }

$subscription = Get-EnvOrAzdValue 'AZURE_SUBSCRIPTION_ID'
if (-not $subscription) { throw 'AZURE_SUBSCRIPTION_ID is not set. Run: azd env set AZURE_SUBSCRIPTION_ID <id>' }
if ($account.sub -ne $subscription) { throw 'The Azure CLI subscription does not match AZURE_SUBSCRIPTION_ID. Run: az account set --subscription <id>' }
$tenant = Get-EnvOrAzdValue 'AZURE_TENANT_ID'
if ($tenant -and $account.tenant -ne $tenant) { throw 'The Azure CLI tenant does not match AZURE_TENANT_ID.' }

# 3. azd resolves AZURE_PRINCIPAL_ID itself; if a value is present, it must be the signed-in user.
$userId = Get-SignedInUserId
$principal = Get-EnvOrAzdValue 'AZURE_PRINCIPAL_ID'
if ($principal -and $principal -ne $userId) {
    throw 'AZURE_PRINCIPAL_ID does not match the user signed in to the Azure CLI. Remove it from the azd environment.'
}

# 4. Role assignments for anyone other than you (managed identities are service principals and are expected).
$resourceGroup = Get-EnvOrAzdValue 'AZURE_RESOURCE_GROUP_NAME'
if (-not $resourceGroup) { $resourceGroup = 'rg-rag-poc' }
$exists = az group exists --name $resourceGroup --subscription $subscription 2>$null
if ($LASTEXITCODE -ne 0) { throw "Could not check whether resource group '$resourceGroup' exists." }
if ("$exists".Trim() -eq 'true') {
    $groupId = "/subscriptions/$subscription/resourceGroups/$resourceGroup"
    $assignmentsJson = az role assignment list --all --subscription $subscription -o json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not list role assignments for the subscription.' }
    $stale = @($assignmentsJson | ConvertFrom-Json | Where-Object {
            ($_.scope -ieq $groupId -or $_.scope -ilike "$groupId/*") -and
            $_.principalType -ne 'ServicePrincipal' -and
            $_.principalId -ne $userId
        })
    if ($stale.Count) {
        Write-Host "Found $($stale.Count) role assignment(s) in '$resourceGroup' for someone other than you:"
        foreach ($item in $stale) {
            Write-Host "  $($item.roleDefinitionName) for a $($item.principalType) at $($item.scope)"
            Write-Host "    az role assignment delete --ids $($item.id)"
        }
        throw 'Remove these role assignments (or confirm they are intended and remove this check), then try again.'
    }
}

# 5. Ingress may only stay on for the client ID that enable-api-ingress.ps1 verified.
if ((Get-EnvOrAzdValue 'API_INGRESS_ENABLED') -eq 'true' -and
    (Get-EnvOrAzdValue 'API_AUTH_CLIENT_ID') -ne (Get-EnvOrAzdValue 'API_INGRESS_VERIFIED_CLIENT_ID')) {
    throw 'API_AUTH_CLIENT_ID changed after ingress was verified. Run: azd env set API_INGRESS_ENABLED false, provision, then run enable-api-ingress.ps1 again.'
}

Write-Host 'Identity check passed: access will be granted only to the signed-in operator.'