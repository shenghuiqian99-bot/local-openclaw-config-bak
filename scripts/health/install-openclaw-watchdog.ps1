Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'OpenClaw Watchdog'
$scriptPath = Join-Path $PSScriptRoot 'openclaw-health-check.ps1'
$schtasksPath = Join-Path $env:WINDIR 'System32\schtasks.exe'

if (-not (Test-Path $scriptPath)) {
    throw "Watchdog script not found: $scriptPath"
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$sid = $identity.User.Value
$startBoundary = (Get-Date).AddMinutes(1).ToString('s')
$escapedPowerShellExe = [System.Security.SecurityElement]::Escape((Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'))
$escapedArguments = [System.Security.SecurityElement]::Escape(('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Repair -Quiet' -f $scriptPath))
$workingDirectory = [System.Security.SecurityElement]::Escape($PSScriptRoot)

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
    <RegistrationInfo>
        <Description>Run the OpenClaw watchdog health check every five minutes without attaching a visible console window.</Description>
        <URI>\$taskName</URI>
    </RegistrationInfo>
    <Principals>
        <Principal id="Author">
            <UserId>$sid</UserId>
            <LogonType>S4U</LogonType>
            <RunLevel>LeastPrivilege</RunLevel>
        </Principal>
    </Principals>
    <Settings>
        <AllowStartOnDemand>true</AllowStartOnDemand>
        <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
        <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
        <StartWhenAvailable>true</StartWhenAvailable>
        <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
        <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
        <AllowHardTerminate>true</AllowHardTerminate>
        <Hidden>false</Hidden>
        <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    </Settings>
    <Triggers>
        <CalendarTrigger>
            <StartBoundary>$startBoundary</StartBoundary>
            <Enabled>true</Enabled>
            <ScheduleByDay>
                <DaysInterval>1</DaysInterval>
            </ScheduleByDay>
            <Repetition>
                <Interval>PT5M</Interval>
                <Duration>P1D</Duration>
                <StopAtDurationEnd>false</StopAtDurationEnd>
            </Repetition>
        </CalendarTrigger>
    </Triggers>
    <Actions Context="Author">
        <Exec>
            <Command>$escapedPowerShellExe</Command>
            <Arguments>$escapedArguments</Arguments>
            <WorkingDirectory>$workingDirectory</WorkingDirectory>
        </Exec>
    </Actions>
</Task>
"@

try {
    Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
} catch {
    if (-not (Test-Path $schtasksPath)) {
        throw
    }

    $quotedScriptPath = '"' + $scriptPath + '"'
    $taskCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $quotedScriptPath + ' -Repair -Quiet'
    $createArgs = @(
        '/Create',
        '/TN', $taskName,
        '/SC', 'MINUTE',
        '/MO', '5',
        '/TR', $taskCommand,
        '/F'
    )

    & $schtasksPath @createArgs | Out-Null

    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $task.Settings.Hidden = $false
        $task.Settings.MultipleInstances = 'IgnoreNew'
        $task.Settings.ExecutionTimeLimit = 'PT10M'
        $task.Settings.AllowHardTerminate = $true
        $task.Settings.StartWhenAvailable = $true
        $task.Settings.DisallowStartIfOnBatteries = $false
        $task.Settings.StopIfGoingOnBatteries = $false
        Set-ScheduledTask -InputObject $task | Out-Null
    } catch {
        Write-Warning "Created watchdog task with schtasks fallback but could not fully tune task settings: $($_.Exception.Message)"
    }
}

Get-ScheduledTask -TaskName $taskName | Select-Object TaskName, State, @{Name='Hidden';Expression={$_.Settings.Hidden}}, @{Name='UserId';Expression={$_.Principal.UserId}}, @{Name='LogonType';Expression={$_.Principal.LogonType}}, @{Name='Execute';Expression={$_.Actions.Execute}}, @{Name='Arguments';Expression={$_.Actions.Arguments}} | Format-List | Out-String
