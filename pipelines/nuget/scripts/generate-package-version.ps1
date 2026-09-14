Import-Module ([System.IO.Path]::GetFullPath("$PSScriptRoot/../../../utilities/throw-error-helper.psm1"))
$ErrorActionPreference = 'Stop'

$packagePath = $env:PACKAGE_PATH
$packageName = $env:PACKAGE_NAME
$isStableRelease = $env:IS_STABLE_RELEASE
$sourceBranch = $env:BUILD_SOURCEBRANCH
$packageVersion = $env:PACKAGE_VERSION

if ([string]::IsNullOrWhiteSpace($packagePath)) {
    $packagePath = ""
}
if ([string]::IsNullOrWhiteSpace($packageName)) {
    ThrowError("Package Name is not provided.")
}
if ([string]::IsNullOrWhiteSpace($isStableRelease)) {
    ThrowError("Stable Release flag is not provided.")
}

if (-not [string]::IsNullOrWhiteSpace($packageVersion)) {
    # Version was supplied by the caller (e.g. computed once for several packages
    # that must share a version). Skip the git-based calculation and only emit outputs.
    $version = $packageVersion.Trim()
    Write-Host "Using supplied version: $version"
}
else {
    git fetch origin main --quiet
    if ($LASTEXITCODE -ne 0) { ThrowError("Git command failed with exit code $LASTEXITCODE") }

    $utcNow = [System.DateTime]::UtcNow
    $localTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Europe/Stockholm")
    $localNow = [System.TimeZoneInfo]::ConvertTime($utcNow, $localTimeZone)
    $datePart = "$($localNow.Year).$($localNow.Month).$($localNow.Day)"

    if ($isStableRelease -eq "true") {
        $mainCount = git rev-list --count origin/main -- $packagePath
        if ($LASTEXITCODE -ne 0) { ThrowError("Git command failed with exit code $LASTEXITCODE") }

        $version = "$datePart.$mainCount"
    }
    else {
        $base = git merge-base HEAD origin/main
        if ($LASTEXITCODE -ne 0) { ThrowError("Git command failed with exit code $LASTEXITCODE") }

        $baselineCount = git rev-list --count "$base" -- $packagePath
        if ($LASTEXITCODE -ne 0) { ThrowError("Git command failed with exit code $LASTEXITCODE") }

        $delta = git rev-list --count HEAD ^origin/main
        if ($LASTEXITCODE -ne 0) { ThrowError("Git command failed with exit code $LASTEXITCODE") }

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sourceBranch)
        $hash = $sha256.ComputeHash($bytes)
        $branchId = ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 8).ToLower()

        $version = "$datePart.$baselineCount-dev.$branchId.$delta"
    }
}

$versionTagPrefix = $packageName.ToLower()
$outputVariablePrefix = $packageName.ToUpper()
$versionTag = "$versionTagPrefix/$version"

Write-Host "##vso[task.setvariable variable=$($outputVariablePrefix)_PACKAGE_VERSION;isOutput=true]$version"
Write-Host "##vso[task.setvariable variable=$($outputVariablePrefix)_PACKAGE_VERSION_TAG;isOutput=true]$versionTag"

Write-Host "Computed version: $versionTag"
