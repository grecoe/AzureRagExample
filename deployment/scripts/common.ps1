# Shared helpers, dot-sourced by the other scripts. Nothing here writes to disk: Graph request
# bodies and tokens stay in memory, and identifiers are resolved at run time, never stored.
$script:AzureCliAppId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
$script:GraphRoot = 'https://graph.microsoft.com/v1.0'
$script:GraphToken = $null

function Get-AzdValue([string] $Name) {
    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return "$value".Trim()
}

function Get-EnvOrAzdValue([string] $Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($value) { return $value.Trim() }
    return Get-AzdValue $Name
}

function Get-ItemCount($Items) {
    return @($Items | Where-Object { $null -ne $_ }).Count
}

function Get-SignedInUserId {
    $id = az ad signed-in-user show --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not "$id".Trim()) { throw 'Could not read the signed-in user from Microsoft Entra ID. Run: az login' }
    return "$id".Trim()
}

function Invoke-Graph {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        $Body,
        [int[]] $RetryOn = @(404),
        [int] $Attempts = 6
    )
    if (-not $script:GraphToken) {
        $token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not "$token".Trim()) { throw 'Could not get a Microsoft Graph token. Run: az login' }
        $script:GraphToken = "$token".Trim()
    }
    $request = @{
        Method      = $Method
        Uri         = "$script:GraphRoot$Path"
        Headers     = @{ Authorization = "Bearer $script:GraphToken" }
        ContentType = 'application/json'
    }
    if ($null -ne $Body) { $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress }
    for ($attempt = 1; ; $attempt++) {
        try { return Invoke-RestMethod @request }
        catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int] $_.Exception.Response.StatusCode }
            # New objects take a few seconds to replicate across Entra ID.
            if ($status -in $RetryOn -and $attempt -lt $Attempts) { Start-Sleep -Seconds (5 * $attempt); continue }
            throw "Microsoft Graph $Method $($Path.Split('?')[0]) failed with HTTP $status."
        }
    }
}

# Returns a list of problems; an empty list means the registration is exactly as expected.
function Test-Registration([string] $ClientId, [string] $UserId) {
    $problems = [System.Collections.Generic.List[string]]::new()
    $app = Invoke-Graph GET "/applications(appId='$ClientId')"
    $sp = Invoke-Graph GET "/servicePrincipals(appId='$ClientId')"

    if ($app.signInAudience -ne 'AzureADMyOrg') { $problems.Add('The app registration is not single-tenant.') }
    if ((@($app.identifierUris) -join ',') -ne "api://$ClientId") { $problems.Add("The identifier URI is not exactly api://<clientId>.") }
    if ($app.api.requestedAccessTokenVersion -ne 2) { $problems.Add('The app registration does not request v2 access tokens.') }
    $scopes = @($app.api.oauth2PermissionScopes | Where-Object { $null -ne $_ })
    if ($scopes.Count -ne 1 -or $scopes[0].value -ne 'user_impersonation' -or -not $scopes[0].isEnabled) {
        $problems.Add('The app registration must expose exactly one enabled scope, user_impersonation.')
    }
    $preAuthorized = @($app.api.preAuthorizedApplications | Where-Object { $null -ne $_ })
    if ($preAuthorized.Count -ne 1 -or $preAuthorized[0].appId -ne $script:AzureCliAppId) {
        $problems.Add('The Azure CLI must be the only pre-authorized client application.')
    }
    foreach ($item in @(@{ Name = 'app registration'; Value = $app }, @{ Name = 'service principal'; Value = $sp })) {
        if ((Get-ItemCount $item.Value.passwordCredentials) -or (Get-ItemCount $item.Value.keyCredentials)) {
            $problems.Add("The $($item.Name) has a client secret or certificate; this API needs neither.")
        }
    }
    $appOwners = Invoke-Graph GET "/applications/$($app.id)/owners?`$select=id"
    $spOwners = Invoke-Graph GET "/servicePrincipals/$($sp.id)/owners?`$select=id"
    if (Get-ItemCount (@($appOwners.value) + @($spOwners.value) | Where-Object { $_ -and $_.id -ne $UserId })) {
        $problems.Add('Someone other than you owns the app registration or its service principal.')
    }
    if (-not $sp.appRoleAssignmentRequired) { $problems.Add('The service principal does not require assignment.') }
    $assigned = Invoke-Graph GET "/servicePrincipals/$($sp.id)/appRoleAssignedTo"
    $assignees = @($assigned.value | Where-Object { $null -ne $_ })
    if ($assigned.'@odata.nextLink' -or $assignees.Count -ne 1 -or $assignees[0].principalId -ne $UserId) {
        $problems.Add('You must be the only principal assigned to the API.')
    }
    return , $problems
}
