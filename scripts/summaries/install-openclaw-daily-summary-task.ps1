param(
    [string]$TaskName = 'OpenClaw Daily Summary',
    [string]$RunTime = '00:15',
    [switch]$RunNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'export-openclaw-daily-summary.ps1'
$schtasksPath = Join-Path $env:WINDIR 'System32\schtasks.exe'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Daily summary script not found: $scriptPath"
}

if (-not (Test-Path -LiteralPath $schtasksPath)) {
    throw "schtasks.exe not found: $schtasksPath"
}

$quotedScriptPath = '"' + $scriptPath + '"'
$taskCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + $quotedScriptPath

$createArgs = @(
    '/Create',
    '/TN', $TaskName,
    '/SC', 'DAILY',
    '/ST', $RunTime,
    '/TR', $taskCommand,
    '/F'
)

& $schtasksPath @createArgs | Out-Null

try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $task.Settings.Hidden = $false
    $task.Settings.MultipleInstances = 'IgnoreNew'
    $task.Settings.ExecutionTimeLimit = 'PT30M'
    $task.Settings.AllowHardTerminate = $true
    $task.Settings.StartWhenAvailable = $true
    $task.Settings.DisallowStartIfOnBatteries = $false
    $task.Settings.StopIfGoingOnBatteries = $false
    Set-ScheduledTask -InputObject $task | Out-Null
} catch {
    Write-Warning "Task created but extended settings could not be applied: $($_.Exception.Message)"
}

if ($RunNow) {
    Start-ScheduledTask -TaskName $TaskName
}

& $schtasksPath /Query /TN $TaskName /V /FO LIST | Out-String