# ------------ Parameters ------------
[CmdletBinding()]
param
(
    [Parameter(Mandatory = $true)]
    [String] $environment,

    [Parameter(Mandatory = $true)]
    [PSCustomObject] $sqlConfiguration
)
$ErrorActionPreference = 'Stop'

Write-Host "Initializing variables..."
$entraGroups = @{
    directoryReaders        = 'A ROLE Directory Readers'
    developersUme           = 'Azure DevOps - Utvecklare'
    developersCld           = 'A IT Utvecklare'
    developersCldPrivileged = 'A ROLE IT Utvecklare Privilegierad'
    developersCldAkut       = 'A ROLE IT Utvecklare Akut'
}
$serverOwner = switch ($environment) {
    'dev' { $entraGroups.developersCld }
    'test' { $entraGroups.developersCldPrivileged }
    'prod' { $entraGroups.developersCldAkut }
    default {
        throw "Unknown environment: $environment"
    }
}

$serverName = $sqlConfiguration.serverName
$serverPrincipalId = $sqlConfiguration.serverPrincipalId
$serverInstance = $sqlConfiguration.serverFullyQualifiedDomainName
$databases = $sqlConfiguration.databases.PSObject.Properties | ForEach-Object { $_.Value }

$createUserQuery = @"
BEGIN TRANSACTION;
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'`$(Identity)')
    BEGIN
        CREATE USER [`$(Identity)] FROM EXTERNAL PROVIDER WITH DEFAULT_SCHEMA = dbo;
    END
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    THROW;
END CATCH;
"@

$addUserQuery = @"
BEGIN TRANSACTION;
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'`$(Identity)')
    BEGIN
        CREATE USER [`$(Identity)] FROM EXTERNAL PROVIDER WITH DEFAULT_SCHEMA = dbo;
    END
    ALTER ROLE db_datareader ADD MEMBER [`$(Identity)];
    ALTER ROLE db_datawriter ADD MEMBER [`$(Identity)];
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    THROW;
END CATCH;
"@

$dropStaleUserQuery = @"
IF EXISTS (
    SELECT 1 FROM sys.database_principals
    WHERE name = N'`$(Identity)'
        AND sid <> CAST(CAST(N'`$(ClientId)' AS uniqueidentifier) AS varbinary(16))
)
BEGIN
    DROP USER [`$(Identity)];
    SELECT 1 AS Dropped;
END
"@

$addOwnerQuery = @"
BEGIN TRANSACTION;
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'`$(Identity)')
    BEGIN
        CREATE USER [`$(Identity)] FROM EXTERNAL PROVIDER WITH DEFAULT_SCHEMA = dbo;
    END
    ALTER ROLE db_owner ADD MEMBER [`$(Identity)];
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    THROW;
END CATCH;
"@

function Get-ServicePrincipalClientId([String] $displayName) {
    $escapedDisplayName = $displayName.Replace("'", "''")
    $clientIds = @(az ad sp list `
            --filter "displayName eq '$escapedDisplayName'" `
            --query "[].appId" `
            -o tsv)

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to look up service principal [$displayName]."
    }
    if ($clientIds.Count -gt 1) {
        throw "Found $($clientIds.Count) service principals named [$displayName]."
    }

    return $clientIds | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($serverName)) {
    throw "SQL Server name is not provided."
}
if ([string]::IsNullOrWhiteSpace($serverPrincipalId)) {
    throw "SQL Server principal ID is not provided."
}
if ([string]::IsNullOrWhiteSpace($serverInstance)) {
    throw "SQL Server fully qualified domain name is not provided."
}
foreach ($database in $databases) {
    if ([string]::IsNullOrWhiteSpace($database.id)) {
        throw "Database ID is not provided."
    }
    if ([string]::IsNullOrWhiteSpace($database.name)) {
        throw "Database name is not provided."
    }
}

Write-Host "Validating script permissions..."
$directoryReadersGroupId = az ad group show `
    --group $entraGroups.directoryReaders `
    --query id `
    -o tsv

$isSqlServerDirectoryReader = az ad group member check `
    --group $directoryReadersGroupId `
    --member-id $serverPrincipalId `
    --query value `
    -o tsv

if ($isSqlServerDirectoryReader -eq "true") {
    Write-Host "[$serverName] is allowed to read Active Directory groups."
}
else {
    Write-Host "[$serverName] does not have permission to read Active Directory groups."
    Write-Host "Adding [$serverName] to [$($entraGroups.directoryReaders)]..."
    az ad group member add --group $directoryReadersGroupId --member-id $serverPrincipalId
}

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Host "Installing SqlServer module..."
    Install-Module -Name SqlServer -Scope CurrentUser -Force -SkipPublisherCheck
}

Write-Host "Retrieving access token..."
$accessToken = az account get-access-token `
    --resource https://database.windows.net/ `
    --query accessToken `
    -o tsv

$attempt = 0
$maxRetries = 12
$delay = 10
while ($attempt -lt $maxRetries) {
    try {
        Write-Host "Validating connection..."
        Invoke-Sqlcmd `
            -ServerInstance $serverInstance `
            -Database "master" `
            -AccessToken $accessToken `
            -Query "SELECT 1" | Out-Null
        break
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -match "Server identity does not have the Microsoft Entra Directory Readers permission") {
            $attempt++

            if ($attempt -ge $maxRetries) {
                throw "Operation failed after $maxRetries attempts due to permission error."
            }

            Write-Host "Attempt $attempt failed due to permission error. Retrying in $delay seconds..."
            Start-Sleep -Seconds $delay
        }
        else {
            throw "Operation failed due to an unexpected error - $errorMessage"
        }
    }
}

Write-Host "Initializing users on [master]..."

# Create user on master
Write-Host "Creating user [$($serverOwner)]..."
Invoke-Sqlcmd `
    -ServerInstance $serverInstance `
    -Database "master" `
    -AccessToken $accessToken `
    -Query $createUserQuery `
    -Variable @{ Identity = $serverOwner } `
    -OutputSqlErrors $true

if ($environment -eq "dev") {
    # Create user on master - 'A IT Utvecklare'
    Write-Host "Creating user [$($entraGroups.developersCld )]..."
    Invoke-Sqlcmd `
        -ServerInstance $serverInstance `
        -Database "master" `
        -AccessToken $accessToken `
        -Query $createUserQuery `
        -Variable @{ Identity = $entraGroups.developersCld } `
        -OutputSqlErrors $true

    # Create user on master - 'Azure DevOps - Utvecklare'
    Write-Host "Creating user [$($entraGroups.developersUme)]..."
    Invoke-Sqlcmd `
        -ServerInstance $serverInstance `
        -Database "master" `
        -AccessToken $accessToken `
        -Query $createUserQuery `
        -Variable @{ Identity = $entraGroups.developersUme } `
        -OutputSqlErrors $true
}

Write-Host "---"

foreach ($database in $databases) {
    Write-Host "Setting up permissions on [$($database.name)]..."

    # Add Owner
    Write-Host "Adding owner [$serverOwner]..."
    Invoke-Sqlcmd `
        -ServerInstance $serverInstance `
        -Database $database.name `
        -AccessToken $accessToken `
        -Query $addOwnerQuery `
        -Variable @{ Identity = $serverOwner } `
        -OutputSqlErrors $true

    if ($environment -eq "dev") {
        # Add User - 'A IT Utvecklare'
        Write-Host "Adding user [$($entraGroups.developersCld)]..."
        Invoke-Sqlcmd `
            -ServerInstance $serverInstance `
            -Database $database.name `
            -AccessToken $accessToken `
            -Query $addUserQuery `
            -Variable @{ Identity = $entraGroups.developersCld } `
            -OutputSqlErrors $true

        # Add User - 'Azure DevOps - Utvecklare'
        Write-Host "Adding user [$($entraGroups.developersUme)]..."
        Invoke-Sqlcmd `
            -ServerInstance $serverInstance `
            -Database $database.name `
            -AccessToken $accessToken `
            -Query $addUserQuery `
            -Variable @{ Identity = $entraGroups.developersUme } `
            -OutputSqlErrors $true
    }

    foreach ($user in $database.users) {
        $clientId = Get-ServicePrincipalClientId -displayName $user
        if ($clientId) {
            $dropped = Invoke-Sqlcmd `
                -ServerInstance $serverInstance `
                -Database $database.name `
                -AccessToken $accessToken `
                -Query $dropStaleUserQuery `
                -Variable @{ Identity = $user; ClientId = $clientId } `
                -OutputSqlErrors $true

            if ($dropped) {
                Write-Host "Removed user [$user] bound to a replaced identity."
            }
        }

        Write-Host "Adding user [$user]..."
        Invoke-Sqlcmd `
            -ServerInstance $serverInstance `
            -Database $database.name `
            -AccessToken $accessToken `
            -Query $addUserQuery `
            -Variable @{ Identity = $user } `
            -OutputSqlErrors $true
    }

    Write-Host "---"
}

Write-Host "SQL permissions successfully configured"
