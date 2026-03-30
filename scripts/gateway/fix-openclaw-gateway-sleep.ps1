Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "[fix-openclaw] $Message"
}

function Resolve-OpenClawCli {
    $candidates = @(
        (Join-Path $env:APPDATA 'npm\openclaw.cmd'),
        (Join-Path $env:APPDATA 'npm\openclaw'),
        'openclaw.cmd',
        'openclaw'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }

        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    throw 'OpenClaw CLI not found. Install OpenClaw first, then rerun this script.'
}

function Resolve-NodeExe {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw 'node.exe not found. Install Node.js first, then rerun this script.'
}

function Resolve-PowerShellExe {
    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw 'powershell.exe not found. This script requires Windows PowerShell.'
}

function Resolve-OpenClawDist {
    $candidates = @(
        (Join-Path $env:APPDATA 'npm\node_modules\openclaw\dist\index.js'),
        (Join-Path $env:USERPROFILE 'AppData\Roaming\npm\node_modules\openclaw\dist\index.js')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw 'OpenClaw dist/index.js not found under the global npm path.'
}

function Set-GatewayPowerPolicy {
    $wirelessSubgroup = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
    $wirelessPowerSetting = '12bbebe6-58d6-4636-95bb-3217ef867c1a'

    & powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0 | Out-Null
    & powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0 | Out-Null
    & powercfg /setacvalueindex SCHEME_CURRENT $wirelessSubgroup $wirelessPowerSetting 0 | Out-Null
    & powercfg /S SCHEME_CURRENT | Out-Null
}

function Ensure-GatewayLauncher {
    param(
        [string]$NodeExe,
        [string]$OpenClawDist,
        [int]$Port
    )

    $openClawHome = Join-Path $env:USERPROFILE '.openclaw'
    $launcherPath = Join-Path $openClawHome 'gateway.cmd'

    if (-not (Test-Path $openClawHome)) {
        New-Item -ItemType Directory -Path $openClawHome -Force | Out-Null
    }

    $launcherContent = @(
        '@echo off',
        'setlocal',
        ('set "TMPDIR={0}"' -f $env:TEMP),
        ('set "OPENCLAW_GATEWAY_PORT={0}"' -f $Port),
        'set "OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service"',
        'set "OPENCLAW_WINDOWS_TASK_NAME=OpenClaw Gateway"',
        'set "OPENCLAW_SERVICE_MARKER=openclaw"',
        'set "OPENCLAW_SERVICE_KIND=gateway"',
        'set "OPENCLAW_SERVICE_VERSION=2026.3.7"',
        ('"{0}" "{1}" gateway --port {2}' -f $NodeExe, $OpenClawDist, $Port)
    ) -join "`r`n"

    Set-Content -Path $launcherPath -Value $launcherContent -Encoding Ascii
    return $launcherPath
}

function Ensure-GatewayTaskScript {
    param(
        [string]$NodeExe,
        [string]$OpenClawDist,
        [int]$Port
    )

    $openClawHome = Join-Path $env:USERPROFILE '.openclaw'
    $scriptPath = Join-Path $openClawHome 'gateway-task.ps1'
    $escapedNodeExe = $NodeExe.Replace("'", "''")
    $escapedOpenClawDist = $OpenClawDist.Replace("'", "''")

    $scriptContent = @(
        'Set-StrictMode -Version Latest',
        '$ErrorActionPreference = ''Stop''',
        '',
        'function Import-OpenClawUserEnvironment {',
        '    $envKey = ''HKCU:\Environment''',
        '    if (-not (Test-Path $envKey)) {',
        '        return',
        '    }',
        '',
        '    $properties = Get-ItemProperty -Path $envKey -ErrorAction SilentlyContinue',
        '    if (-not $properties) {',
        '        return',
        '    }',
        '',
        '    foreach ($property in $properties.PSObject.Properties) {',
        '        if ($property.Name -in @(''PSPath'', ''PSParentPath'', ''PSChildName'', ''PSDrive'', ''PSProvider'')) {',
        '            continue',
        '        }',
        '',
        '        if ($property.Name -notmatch ''^(OPENCLAW_|OPENAI_|MOONSHOT_|DASHSCOPE_|GEMINI_|ANTHROPIC_|KIMI_|ZAI_|XIAOMI_)'') {',
        '            continue',
        '        }',
        '',
        '        $value = [string]$property.Value',
        '        if ([string]::IsNullOrWhiteSpace($value)) {',
        '            continue',
        '        }',
        '',
        '        Set-Item -Path ("Env:{0}" -f $property.Name) -Value $value',
        '    }',
        '}',
        '',
        'function Test-NetworkReady {',
        '    try {',
        '        $configs = Get-NetIPConfiguration -ErrorAction Stop |',
        '            Where-Object {',
        '                $_.IPv4DefaultGateway -and $_.NetAdapter -and $_.NetAdapter.Status -eq ''Up''',
        '            }',
        '',
        '        return [bool]($configs | Select-Object -First 1)',
        '    }',
        '    catch {',
        '        return $false',
        '    }',
        '}',
        '',
        'function Wait-NetworkReady {',
        '    param(',
        '        [int]$Attempts = 12,',
        '        [int]$SleepSeconds = 5',
        '    )',
        '',
        '    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {',
        '        if (Test-NetworkReady) {',
        '            return $true',
        '        }',
        '',
        '        if ($attempt -lt $Attempts) {',
        '            Start-Sleep -Seconds $SleepSeconds',
        '        }',
        '    }',
        '',
        '    return $false',
        '}',
        '',
        'function Get-RunningGatewayProcesses {',
        '    Get-CimInstance Win32_Process |',
        '        Where-Object {',
        '            $_.Name -eq ''node.exe'' -and',
        ('            $_.CommandLine -like ''*{0}* gateway*''' -f $escapedOpenClawDist),
        '        }',
        '}',
        '',
        'function Stop-RunningGatewayProcesses {',
        '    $gatewayProcesses = Get-RunningGatewayProcesses',
        '    foreach ($process in $gatewayProcesses) {',
        '        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue',
        '    }',
        '}',
        '',
        'function Wait-GatewayShutdown {',
        '    param(',
        '        [int]$Attempts = 20,',
        '        [int]$SleepMilliseconds = 500',
        '    )',
        '',
        '    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {',
        '        if (-not (Get-RunningGatewayProcesses)) {',
        '            return',
        '        }',
        '',
        '        Start-Sleep -Milliseconds $SleepMilliseconds',
        '    }',
        '',
        '    throw ''Timed out waiting for the existing OpenClaw gateway process to exit.''',
        '}',
        '',
        'function Clear-StaleGatewayLocks {',
        '    if (Get-RunningGatewayProcesses) {',
        '        return',
        '    }',
        '',
        '    $lockRoot = Join-Path $env:LOCALAPPDATA ''Temp\openclaw''',
        '    if (-not (Test-Path $lockRoot)) {',
        '        return',
        '    }',
        '',
        '    Get-ChildItem -Path $lockRoot -Filter ''gateway*.lock'' -File -ErrorAction SilentlyContinue |',
        '        Remove-Item -Force -ErrorAction SilentlyContinue',
        '}',
        '',
        '[void](Wait-NetworkReady)',
        'Import-OpenClawUserEnvironment',
        'Stop-RunningGatewayProcesses',
        'Wait-GatewayShutdown',
        'Clear-StaleGatewayLocks',
        ('& ''{0}'' ''{1}'' gateway --port {2}' -f $escapedNodeExe, $escapedOpenClawDist, $Port),
        'exit $LASTEXITCODE'
    ) -join "`r`n"

    Set-Content -Path $scriptPath -Value $scriptContent -Encoding Ascii
    return $scriptPath
}

function Backup-ScheduledTask {
    param([string]$TaskName)

    $backupDir = Join-Path $env:USERPROFILE '.openclaw\task-backups'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backupPath = Join-Path $backupDir ("{0}-{1}.xml" -f ($TaskName -replace '\\', '-'), (Get-Date -Format 'yyyyMMdd-HHmmss'))

    try {
        schtasks /Query /TN $TaskName /XML | Set-Content -Path $backupPath -Encoding Unicode
        return $backupPath
    }
    catch {
        return $null
    }
}

function Register-GatewayTask {
    param(
        [string]$TaskName,
        [string]$PowerShellExe,
        [string]$GatewayTaskScript,
        [int]$DelaySeconds,
        [int]$NetworkDelaySeconds
    )

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userName = $identity.Name
    $sid = $identity.User.Value
    $delay = 'PT{0}S' -f $DelaySeconds
    $networkDelay = 'PT{0}S' -f $NetworkDelaySeconds
    $escapedPowerShellExe = [System.Security.SecurityElement]::Escape($PowerShellExe)
    $escapedArguments = [System.Security.SecurityElement]::Escape(('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $GatewayTaskScript))
    $workingDirectory = [System.Security.SecurityElement]::Escape((Split-Path -Path $GatewayTaskScript -Parent))

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Start OpenClaw Gateway at user logon and restart it after resume, session unlock, or network reconnect.</Description>
    <URI>\$TaskName</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
        <Hidden>false</Hidden>
    <MultipleInstancesPolicy>StopExisting</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <IdleSettings>
      <Duration>PT10M</Duration>
      <WaitTimeout>PT1H</WaitTimeout>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
  </Settings>
  <Triggers>
    <LogonTrigger>
      <UserId>$userName</UserId>
    </LogonTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Delay>$delay</Delay>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
            <EventTrigger>
                <Enabled>true</Enabled>
                <Delay>$networkDelay</Delay>
                <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and EventID=10000]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
            </EventTrigger>
            <SessionStateChangeTrigger>
                <Enabled>true</Enabled>
                <StateChange>SessionUnlock</StateChange>
                <UserId>$userName</UserId>
            </SessionStateChangeTrigger>
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

    Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
}

function Stop-RunningGateway {
    $gatewayProcesses = Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -eq 'node.exe' -and
            $_.CommandLine -like '*openclaw*dist\index.js gateway*'
        }

    foreach ($process in $gatewayProcesses) {
        Stop-Process -Id $process.ProcessId -Force
    }
}

function Test-GatewayStatus {
    param(
        [string]$CliPath,
        [int]$Attempts = 12,
        [int]$SleepSeconds = 5
    )

    $lastOutput = ''

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $lastOutput = & cmd.exe /d /c ('"{0}" gateway status 2>&1' -f $CliPath) | Out-String
        if ($lastOutput -match 'RPC probe:\s+ok') {
            return $lastOutput.Trim()
        }

        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds $SleepSeconds
        }
    }

    throw "Gateway verification failed.`n$lastOutput"
}

function Get-TriggerSummary {
    param([string]$TaskName)

    $task = Get-ScheduledTask -TaskName $TaskName
    return ($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', '
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'This script is only supported on Windows.'
}

$taskName = 'OpenClaw Gateway'
$gatewayPort = 18789
$resumeDelaySeconds = 30
$networkDelaySeconds = 15

Write-Step 'Resolving local OpenClaw installation.'
$cliPath = Resolve-OpenClawCli
$nodeExe = Resolve-NodeExe
$powerShellExe = Resolve-PowerShellExe
$openClawDist = Resolve-OpenClawDist

Write-Step 'Applying power policy for an always-on local gateway.'
Set-GatewayPowerPolicy

Write-Step 'Refreshing the gateway launchers.'
$gatewayLauncher = Ensure-GatewayLauncher -NodeExe $nodeExe -OpenClawDist $openClawDist -Port $gatewayPort
$gatewayTaskScript = Ensure-GatewayTaskScript -NodeExe $nodeExe -OpenClawDist $openClawDist -Port $gatewayPort

Write-Step 'Backing up the current scheduled task if it exists.'
$backupPath = Backup-ScheduledTask -TaskName $taskName

Write-Step 'Registering the wake-aware scheduled task.'
Register-GatewayTask -TaskName $taskName -PowerShellExe $powerShellExe -GatewayTaskScript $gatewayTaskScript -DelaySeconds $resumeDelaySeconds -NetworkDelaySeconds $networkDelaySeconds

Write-Step 'Restarting the gateway.'
Stop-RunningGateway
Start-ScheduledTask -TaskName $taskName

Write-Step 'Verifying task triggers and gateway health.'
$triggerSummary = Get-TriggerSummary -TaskName $taskName
$gatewayStatus = Test-GatewayStatus -CliPath $cliPath

Write-Host ''
Write-Host 'OpenClaw gateway sleep-recovery fix applied successfully.'
Write-Host ('Task: {0}' -f $taskName)
Write-Host ('Launcher: {0}' -f $gatewayLauncher)
Write-Host ('Task script: {0}' -f $gatewayTaskScript)
Write-Host ('Task command: {0} -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $powerShellExe, $gatewayTaskScript)
Write-Host ('Triggers: {0}' -f $triggerSummary)
if ($backupPath) {
    Write-Host ('Backup XML: {0}' -f $backupPath)
}
Write-Host ''
Write-Host $gatewayStatus