param(
    [string]$automationAccountName,
    [string]$resourceGroupName,
    [string]$runbookResourceName,
    [Alias('scheduleName')]
    [string]$scheduleNames,
    [string]$shouldLinkSchedule
)

$azAutomationModule = Get-Module Az.Automation
if (-Not $azAutomationModule) {
    Write-Host "Installing and importing Az.Automation module"
    Install-Module Az.Automation -Scope CurrentUser -Force
    Import-Module Az.Automation
}

$requestedScheduleNames = @(
    $scheduleNames -split ',' `
    | ForEach-Object { $_.Trim() } `
    | Where-Object { -Not [string]::IsNullOrWhiteSpace($_) }
)

if ($shouldLinkSchedule -eq 'true' -And $requestedScheduleNames.Count -eq 0) {
    throw "Script was set to link a schedule but no schedule name was given"
}

Write-Host "Retreiving currently linked schedules"
$currentlyLinkedSchedules = Get-AzAutomationScheduledRunbook `
    -AutomationAccountName $automationAccountName `
    -ResourceGroupName $resourceGroupName `
    -RunbookName $runbookResourceName `

Write-Host "Found $($currentlyLinkedSchedules.Count) linked schedule(s)"

foreach ($schedule in $currentlyLinkedSchedules) {
    Write-Host "Unlinking schedule $($schedule.ScheduleName) from runbook"
    UnRegister-AzAutomationScheduledRunbook `
        -AutomationAccountName $automationAccountName `
        -ResourceGroupName $resourceGroupName `
        -Name $runbookResourceName `
        -ScheduleName $schedule.ScheduleName `
        -Force `
    | Out-Null
}

if ($shouldLinkSchedule -eq 'true') {
    foreach ($requestedScheduleName in $requestedScheduleNames) {
        Write-Host "Linking runbook to schedule $requestedScheduleName"
        Register-AzAutomationScheduledRunbook `
            -AutomationAccountName $automationAccountName `
            -ResourceGroupName $resourceGroupName `
            -Name $runbookResourceName `
            -ScheduleName $requestedScheduleName `
        | Out-Null
    }
}
else {
    Write-Host "Script was set to not link any schedule"
}

Write-Host "Finished!"
