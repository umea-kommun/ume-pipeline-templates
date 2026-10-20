Import-Module ([System.IO.Path]::GetFullPath("$PSScriptRoot/../../../utilities/throw-error-helper.psm1"))
$ErrorActionPreference = 'Stop'

$appPath = $env:APP_PATH
$entraTenantId = $env:ENTRA_TENANT_ID
$shouldMergeExistingConfig = $env:SHOULD_MERGE_EXISTING_CONFIG -eq 'true'

if ([string]::IsNullOrWhiteSpace($appPath)) {
    ThrowError("App Path is not provided.")
}
if (-not (Test-Path -LiteralPath $appPath -PathType Container)) {
    ThrowError("App Path [$appPath] does not exist.")
}
if ([string]::IsNullOrWhiteSpace($entraTenantId)) {
    ThrowError("Entra Tenant Id is not provided.")
}

$configPath = Join-Path $appPath 'staticwebapp.config.json'

$config = [ordered]@{}
if ($shouldMergeExistingConfig -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Host "Merging into [$configPath]"
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
}

# Static Web Apps reads staticwebapp.config.json from any subfolder of app_location.
Get-ChildItem -LiteralPath $appPath -Recurse -File -Filter 'staticwebapp.config.json' | ForEach-Object {
    Write-Host "Removing [$($_.FullName)]"
    Remove-Item -LiteralPath $_.FullName
}

$config.auth = @{
    identityProviders = @{
        azureActiveDirectory = @{
            registration = [ordered]@{
                openIdIssuer            = "https://login.microsoftonline.com/$entraTenantId/v2.0"
                clientIdSettingName     = 'AZURE_CLIENT_ID'
                clientSecretSettingName = 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
            }
        }
    }
}

$routes = [System.Collections.Generic.List[object]]::new()
foreach ($route in $config.routes) {
    if (-not $route.allowedRoles -or $route.allowedRoles -contains 'anonymous') {
        $route.allowedRoles = @('authenticated')
    }
    $routes.Add($route)
}
$routes.Add([ordered]@{
        route        = '/*'
        allowedRoles = @('authenticated')
    })
$config.routes = $routes

if (-not $config.responseOverrides) {
    $config.responseOverrides = [ordered]@{}
}
$config.responseOverrides['401'] = [ordered]@{
    statusCode = 302
    redirect   = '/.auth/login/aad'
}
if (-not $config.responseOverrides.Contains('404') -and (Test-Path -LiteralPath (Join-Path $appPath '404.html') -PathType Leaf)) {
    $config.responseOverrides['404'] = @{ rewrite = '/404.html' }
}

$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath
Write-Host "Wrote [$configPath]"
