param(
    [Parameter(Mandatory = $true)]
    [string]$ServerHost,

    [Parameter(Mandatory = $true)]
    [string]$ServerUser,

    [int]$ServerPort = 22,
    [int]$RemoteGatewayPort = 28789,
    [int]$LocalGatewayPort = 18789,
    [string]$KeyPath = '',
    [string]$TaskName = 'OpenClaw ECS Reverse Tunnel'
)

  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'start-openclaw-ecs-reverse-tunnel.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Tunnel script not found: $scriptPath"
}

if ([string]::IsNullOrWhiteSpace($KeyPath)) {
  throw 'KeyPath is required for scheduled tunnel tasks. Password-based SSH cannot run unattended from Task Scheduler.'
}

$resolvedKeyPath = if ($KeyPath) { (Resolve-Path -LiteralPath $KeyPath).Path } else { '' }
$launcherDir = Join-Path $env:USERPROFILE '.openclaw'
$launcherPath = Join-Path $launcherDir 'start-openclaw-ecs-tunnel-task.ps1'
$xmlPath = Join-Path $env:TEMP 'openclaw-ecs-reverse-tunnel-task.xml'
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$launcherCommand = "& '$scriptPath' -ServerHost '$ServerHost' -ServerUser '$ServerUser' -ServerPort $ServerPort -RemoteGatewayPort $RemoteGatewayPort -LocalGatewayPort $LocalGatewayPort"
if ($resolvedKeyPath) {
    $launcherCommand += " -KeyPath '$resolvedKeyPath'"
}
$launcherCommand += ' -RunInBackground'

$launcherLines = @(
    'Set-StrictMode -Version Latest',
  '$ErrorActionPreference = ''Stop''',
    $launcherCommand
)
Set-Content -LiteralPath $launcherPath -Value $launcherLines -Encoding UTF8

$escapedUser = [System.Security.SecurityElement]::Escape($currentUser)
$escapedLauncher = [System.Security.SecurityElement]::Escape($launcherPath)
$runLevel = if ($isAdministrator) { 'HighestAvailable' } else { 'LeastPrivilege' }
$triggerXml = @"
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$escapedUser</UserId>
    </LogonTrigger>
    <SessionStateChangeTrigger>
      <Enabled>true</Enabled>
      <StateChange>SessionUnlock</StateChange>
      <UserId>$escapedUser</UserId>
    </SessionStateChangeTrigger>
"@

if ($isAdministrator) {
    $triggerXml += @"
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT30S</Delay>
    </BootTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription><![CDATA[<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>]]></Subscription>
      <Delay>PT15S</Delay>
    </EventTrigger>
"@
}

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Keep the local OpenClaw gateway reachable from ECS through a reverse SSH tunnel.</Description>
    <Author>$escapedUser</Author>
  </RegistrationInfo>
  <Triggers>
$triggerXml
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$escapedUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>$runLevel</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File &quot;$escapedLauncher&quot;</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Set-Content -LiteralPath $xmlPath -Value $xml -Encoding Unicode

if (-not $isAdministrator) {
  Write-Warning 'Task installer is running without elevation. Falling back to Logon + SessionUnlock triggers only.'
}

& schtasks.exe /Create /TN "$TaskName" /XML $xmlPath /F | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Failed to create scheduled task '$TaskName'. Exit code: $LASTEXITCODE"
}

& schtasks.exe /Run /TN "$TaskName" | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Warning "Scheduled task created, but immediate start failed with exit code $LASTEXITCODE. You can launch it manually from Task Scheduler."
}

Write-Output "Installed scheduled task '$TaskName' and wrote launcher to $launcherPath"