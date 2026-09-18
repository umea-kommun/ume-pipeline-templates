Import-Module ([System.IO.Path]::GetFullPath("$PSScriptRoot/../../../utilities/throw-error-helper.psm1"))
$ErrorActionPreference = 'Stop'

$accessToken = $env:SYSTEM_ACCESSTOKEN
$ticketIdsString = $env:TICKET_IDS
$tag = $env:TAG
$devopsBaseUrl = $env:SYSTEM_COLLECTIONURI
$projectName = $env:SYSTEM_TEAMPROJECT

if ([string]::IsNullOrWhiteSpace($accessToken)) {
    ThrowError("Access Token is not provided.")
}
if ([string]::IsNullOrWhiteSpace($ticketIdsString)) {
    Write-Host "No tickets to initialize."
    exit 0
}
if ([string]::IsNullOrWhiteSpace($tag)) {
    ThrowError("Tag is not provided.")
}
if ([string]::IsNullOrWhiteSpace($devopsBaseUrl)) {
    ThrowError("DevOps Base URL is not provided.")
}
if ([string]::IsNullOrWhiteSpace($projectName)) {
    ThrowError("Project Name is not provided.")
}

$authenticationHeader = @{
    Authorization = "Bearer $accessToken"
}
$patchAuthenticationHeader = ($authenticationHeader + @{ "Content-Type" = "application/json-patch+json" })
$baseUrl = "$devopsBaseUrl$projectName/_apis"
$apiVersion = "api-version=7.1"

$iterationsUrl = "$baseUrl/work/teamsettings/iterations?$apiVersion"
$iterations = Invoke-RestMethod -Headers $authenticationHeader -Method GET -Uri $iterationsUrl
$currentIteration = $iterations.value | Where-Object { $_.attributes.timeFrame -eq 'current' }
$currentIterationPath = $currentIteration.path

$fieldsToUpdateFirst = @(
    @{
        op    = "add"
        path  = "/fields/System.State"
        value = "Active"
    }
)
$fieldsToUpdate = @(
    @{
        op    = "add"
        path  = "/fields/System.Tags"
        value = "$tag"
    }
    @{
        op    = "add"
        path  = "/fields/System.IterationPath"
        value = "$currentIterationPath"
    }
    @{
        op    = "add"
        path  = "/fields/System.State"
        value = "Closed"
    }
)

function Invoke-WorkItemPatch {
    param (
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][string] $Body,
        [int] $MaxAttempts = 3
    )

    for ($attempt = 1; ; $attempt++) {
        try {
            Invoke-RestMethod -Headers $patchAuthenticationHeader -Method PATCH -Uri $Uri -Body $Body > $null
            return
        }
        catch {
            $errorCode = $null
            try {
                $errorCode = ($_.ErrorDetails.Message | ConvertFrom-Json).errorCode
            }
            catch {
                # Response body was not the expected JSON, let the original error surface
            }

            # 600122 (WorkItemRevisionMismatchException) means the work item changed between our
            # consecutive updates, since server side rules from the previous update are still settling.
            if ($errorCode -ne 600122 -or $attempt -ge $MaxAttempts) {
                throw
            }

            Write-Host "Work item update conflicted, retrying ($attempt/$MaxAttempts)."
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

$ticketIds = $ticketIdsString -split ';'
foreach ($ticketId in $ticketIds) {
    $ticketUrl = "$baseUrl/wit/workitems/$($ticketId)?$apiVersion"

    # Set State to Active first so tickets are placed at the top when closed
    $body = , $fieldsToUpdateFirst | ConvertTo-Json -Depth 10
    Invoke-WorkItemPatch -Uri $ticketUrl -Body $body

    $body = , $fieldsToUpdate | ConvertTo-Json -Depth 10
    Invoke-WorkItemPatch -Uri $ticketUrl -Body $body

    Write-Host "Updated ticket fields for ticket #$ticketId"
    $fieldsToUpdate | ForEach-Object {
        Write-Host "    - $($_.path): $($_.value)"
    }
}

Write-Host "All release tickets initialized successfully."