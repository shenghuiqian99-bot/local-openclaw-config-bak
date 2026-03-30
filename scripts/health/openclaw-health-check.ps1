param(
    [switch]$Repair,
    [switch]$Quiet,
    [int]$FailureThreshold = 2,
    [int]$RepairCooldownMinutes = 15
)

###############################################################################
# OpenClaw Watchdog 健康检查脚本
#
# 功能说明:
#   - 定时检查 OpenClaw Gateway 服务健康状态
#   - 检查 RPC 接口、频道连接、飞书配置等
#   - 检测到故障时自动尝试修复（重启 Gateway）
#
# 启动方式:
#   - Windows 定时任务 "OpenClaw Watchdog" 每5分钟执行一次
#   - 可手动执行: powershell -File openclaw-health-check.ps1 -Repair -Quiet
#
# 修复策略:
#   - 连续失败2次后触发自动修复
#   - 修复后有15分钟冷却时间防止频繁重启
###############################################################################

Write-Host "========================================" -ForegroundColor Yellow
Write-Host " [openclaw-health-check.ps1] OpenClaw Watchdog" -ForegroundColor Yellow
Write-Host " Checking Gateway RPC / Channels / Feishu" -ForegroundColor Gray
Write-Host " Full Path: $($MyInvocation.MyCommand.Path)" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$result = [ordered]@{}
$watchdogHome = Join-Path $env:USERPROFILE '.openclaw'
$statePath = Join-Path $watchdogHome 'watchdog-state.json'
$mutex = New-Object System.Threading.Mutex($false, 'Local\OpenClawWatchdog')
$mutexAcquired = $false

if (-not (Test-Path $watchdogHome)) {
    New-Item -ItemType Directory -Path $watchdogHome -Force | Out-Null
}

function Get-WatchdogState {
    if (-not (Test-Path $statePath)) {
        return [ordered]@{
            consecutiveGatewayFailures = 0
            lastGatewayFailureAt = $null
            lastHealthyAt = $null
            lastRepairAt = $null
            lastRepairReason = $null
        }
    }

    try {
        $raw = Get-Content -Path $statePath -Raw -ErrorAction Stop
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $consecutiveGatewayFailures = 0
        if ($null -ne $parsed.consecutiveGatewayFailures) {
            $consecutiveGatewayFailures = [int]$parsed.consecutiveGatewayFailures
        }

        return [ordered]@{
            consecutiveGatewayFailures = $consecutiveGatewayFailures
            lastGatewayFailureAt = $parsed.lastGatewayFailureAt
            lastHealthyAt = $parsed.lastHealthyAt
            lastRepairAt = $parsed.lastRepairAt
            lastRepairReason = $parsed.lastRepairReason
        }
    } catch {
        return [ordered]@{
            consecutiveGatewayFailures = 0
            lastGatewayFailureAt = $null
            lastHealthyAt = $null
            lastRepairAt = $null
            lastRepairReason = 'state parse failed'
        }
    }
}

function Save-WatchdogState {
    param($State)

    $State | ConvertTo-Json -Depth 4 | Set-Content -Path $statePath -Encoding Ascii
}

function Get-UtcNowString {
    return [DateTimeOffset]::UtcNow.ToString('o')
}

function Get-DateTimeOffsetOrNull {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [DateTimeOffset]::Parse($Value)
    } catch {
        return $null
    }
}

function Test-Contains {
    param(
        [string]$Text,
        [string]$Needle
    )

    return ($Text -and $Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Invoke-GatewayRepair {
    $gatewayTask = Join-Path $env:USERPROFILE '.openclaw\gateway-task.ps1'
    if (-not (Test-Path $gatewayTask)) {
        throw "Gateway wrapper script not found: $gatewayTask"
    }

    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $gatewayTask | Out-Null
}

try {
    $mutexAcquired = $mutex.WaitOne(0)
    if (-not $mutexAcquired) {
        $result.skipped = 'another watchdog instance is already running'
        if ($Quiet) {
            'SKIPPED'
        } else {
            $result | ConvertTo-Json -Depth 6
        }
        return
    }
} catch {
    $result.mutexError = $_.Exception.Message
}

$state = Get-WatchdogState
$nowUtc = Get-UtcNowString

try {
    $gatewayStatus = openclaw gateway status | Out-String
    $result.gatewayStatus = $gatewayStatus.Trim()
} catch {
    $result.gatewayStatusError = $_.Exception.Message
}

try {
    $deepStatus = openclaw status --deep | Out-String
    $result.deepStatus = $deepStatus.Trim()
} catch {
    $result.deepStatusError = $_.Exception.Message
}

try {
    $channelStatus = openclaw channels status --probe | Out-String
    $result.channelStatus = $channelStatus.Trim()
} catch {
    $result.channelStatusError = $_.Exception.Message
}

try {
    $memoryStatus = openclaw memory status --deep | Out-String
    $result.memoryStatus = $memoryStatus.Trim()
} catch {
    $result.memoryStatusError = $_.Exception.Message
}

$needsRepair = $false
$repairReasons = @()
$gatewayHealthy = $false
$channelHealthy = $false

if ($result.Contains('gatewayStatus')) {
    $hasRpcProbe = Test-Contains -Text $result.gatewayStatus -Needle 'RPC probe: ok'
    $hasListener = Test-Contains -Text $result.gatewayStatus -Needle 'Listening: 127.0.0.1:18789'
    $gatewayHealthy = ($hasRpcProbe -and $hasListener)

    if (-not $hasRpcProbe) {
        $needsRepair = $true
        $repairReasons += 'gateway rpc probe not ok'
    }
    if (-not $hasListener) {
        $needsRepair = $true
        $repairReasons += 'gateway loopback listener missing'
    }
} else {
    $needsRepair = $true
    $repairReasons += 'gateway status command failed'
}

if ($result.Contains('channelStatus')) {
    $channelHealthy = (
        (Test-Contains -Text $result.channelStatus -Needle 'Gateway reachable.') -and
        (Test-Contains -Text $result.channelStatus -Needle 'Feishu default: enabled, configured, running, works')
    )

    if (-not $channelHealthy) {
        $repairReasons += 'feishu probe not healthy'
    }
} else {
    $repairReasons += 'channel status command failed'
}

$result.gatewayHealthy = $gatewayHealthy
$result.channelHealthy = $channelHealthy

if ($gatewayHealthy) {
    $state.consecutiveGatewayFailures = 0
    $state.lastHealthyAt = $nowUtc
} elseif ($needsRepair) {
    $state.consecutiveGatewayFailures = [int]$state.consecutiveGatewayFailures + 1
    $state.lastGatewayFailureAt = $nowUtc
}

$lastRepairAt = Get-DateTimeOffsetOrNull -Value $state.lastRepairAt
$cooldownActive = $false
if ($lastRepairAt) {
    $cooldownUntil = $lastRepairAt.AddMinutes($RepairCooldownMinutes)
    $cooldownActive = ($cooldownUntil -gt [DateTimeOffset]::UtcNow)
    if ($cooldownActive) {
        $result.cooldownUntil = $cooldownUntil.ToString('o')
    }
}

$repairEligible = (
    $Repair -and
    $needsRepair -and
    ($state.consecutiveGatewayFailures -ge $FailureThreshold) -and
    (-not $cooldownActive)
)

$result.failureThreshold = $FailureThreshold
$result.repairCooldownMinutes = $RepairCooldownMinutes
$result.consecutiveGatewayFailures = $state.consecutiveGatewayFailures
$result.needsRepair = $needsRepair
$result.repairEligible = $repairEligible
$result.repairReasons = $repairReasons

if ($repairEligible) {
    try {
        Invoke-GatewayRepair
        Start-Sleep -Seconds 8
        $result.repairAttempted = $true
        $state.lastRepairAt = Get-UtcNowString
        $state.lastRepairReason = (($repairReasons -join '; ').Trim())
        $result.postRepairGatewayStatus = (openclaw gateway status | Out-String).Trim()
        $result.postRepairChannelStatus = (openclaw channels status --probe | Out-String).Trim()

        if (Test-Contains -Text $result.postRepairGatewayStatus -Needle 'RPC probe: ok') {
            $state.consecutiveGatewayFailures = 0
            $state.lastHealthyAt = Get-UtcNowString
        }
    } catch {
        $result.repairAttempted = $true
        $result.repairError = $_.Exception.Message
    }
} else {
    $result.repairAttempted = $false
    if ($Repair -and $needsRepair -and $cooldownActive) {
        $result.repairSkipped = 'cooldown active'
    } elseif ($Repair -and $needsRepair -and ($state.consecutiveGatewayFailures -lt $FailureThreshold)) {
        $result.repairSkipped = 'failure threshold not reached'
    }
}

$missionControlUrl = 'http://127.0.0.1:3000/api/openclaw/status'
try {
    $missionControl = Invoke-RestMethod -Uri $missionControlUrl -Method Get -TimeoutSec 8
    $result.missionControl = $missionControl | ConvertTo-Json -Depth 6
} catch {
    $result.missionControlError = $_.Exception.Message
}

Save-WatchdogState -State $state

if ($Quiet -and -not $needsRepair) {
    'OK'
} else {
    $result | ConvertTo-Json -Depth 6
}

if ($mutexAcquired) {
    $mutex.ReleaseMutex() | Out-Null
}

$mutex.Dispose()
