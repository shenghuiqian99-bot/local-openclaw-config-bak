###############################################################################
# OpenClaw Gateway 核心服务启动脚本
#
# 功能说明:
#   - 这是 OpenClaw Gateway 的核心进程启动脚本
#   - 负责启动 Node.js 进程，监听本地 18789 端口
#   - 提供 RPC 接口供 Mission Control 和客户端连接
#
# 启动方式:
#   - Windows 定时任务 "OpenClaw Gateway" 自动触发
#   - 支持睡眠唤醒后自动重启
#   - 支持网络恢复后自动重连
#
# 端口: 127.0.0.1:18789 (本地 Loopback)
###############################################################################

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " [gateway-task.ps1] OpenClaw Gateway" -ForegroundColor Cyan
Write-Host " Port: 127.0.0.1:18789" -ForegroundColor Gray
Write-Host " Full Path: $($MyInvocation.MyCommand.Path)" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OpenClawNodeExe = 'C:\Program Files\nodejs\node.exe'
$OpenClawPackageRoot = 'C:\Users\RickQ\AppData\Roaming\npm\node_modules\openclaw'
$OpenClawDistEntrypoint = Join-Path $OpenClawPackageRoot 'dist\index.js'

function Import-OpenClawUserEnvironment {
    $envKey = 'HKCU:\Environment'
    if (-not (Test-Path $envKey)) {
        return
    }

    $properties = Get-ItemProperty -Path $envKey -ErrorAction SilentlyContinue
    if (-not $properties) {
        return
    }

    foreach ($property in $properties.PSObject.Properties) {
        if ($property.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) {
            continue
        }

        if ($property.Name -notmatch '^(OPENCLAW_|OPENAI_|MOONSHOT_|DASHSCOPE_|GEMINI_|ANTHROPIC_|KIMI_|MINIMAX_|ZAI_|XIAOMI_)') {
            continue
        }

        $value = [string]$property.Value
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        Set-Item -Path ("Env:{0}" -f $property.Name) -Value $value
    }
}

function Test-NetworkReady {
    try {
        $configs = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object {
                $_.IPv4DefaultGateway -and $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up'
            }

        return [bool]($configs | Select-Object -First 1)
    }
    catch {
        return $false
    }
}

function Wait-NetworkReady {
    param(
        [int]$Attempts = 12,
        [int]$SleepSeconds = 5
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (Test-NetworkReady) {
            return $true
        }

        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds $SleepSeconds
        }
    }

    return $false
}

function Get-RunningGatewayProcesses {
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -eq 'node.exe' -and
            $_.CommandLine -like '*C:\Users\RickQ\AppData\Roaming\npm\node_modules\openclaw\dist\index.js* gateway*'
        }
}

function Stop-RunningGatewayProcesses {
    $gatewayProcesses = Get-RunningGatewayProcesses
    foreach ($process in $gatewayProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Wait-GatewayShutdown {
    param(
        [int]$Attempts = 20,
        [int]$SleepMilliseconds = 500
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (-not (Get-RunningGatewayProcesses)) {
            return
        }

        Start-Sleep -Milliseconds $SleepMilliseconds
    }

    throw 'Timed out waiting for the existing OpenClaw gateway process to exit.'
}

function Clear-StaleGatewayLocks {
    if (Get-RunningGatewayProcesses) {
        return
    }

    $lockRoot = Join-Path $env:LOCALAPPDATA 'Temp\openclaw'
    if (-not (Test-Path $lockRoot)) {
        return
    }

    Get-ChildItem -Path $lockRoot -Filter 'gateway*.lock' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Resolve-PnpmCommand {
    $command = Get-Command 'pnpm.cmd' -ErrorAction SilentlyContinue
    if ($command -and (Test-Path $command.Source)) {
        return $command.Source
    }

    $command = Get-Command 'pnpm' -ErrorAction SilentlyContinue
    if ($command -and (Test-Path $command.Source)) {
        return $command.Source
    }

    foreach ($candidate in @(
        'C:\Users\RickQ\AppData\Roaming\npm\pnpm.cmd',
        'C:\Users\RickQ\AppData\Roaming\npm\pnpm.ps1'
    )) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw 'pnpm was not found; cannot auto-build Control UI assets.'
}

function Ensure-ControlUiAssets {
    $controlUiIndex = Join-Path $OpenClawPackageRoot 'dist\control-ui\index.html'
    if (Test-Path $controlUiIndex) {
        return
    }

    $pnpmCommand = Resolve-PnpmCommand

    Write-Host "Control UI assets missing; running ui:build..."
    Push-Location $OpenClawPackageRoot
    try {
        & $pnpmCommand 'ui:build'
        if ($LASTEXITCODE -ne 0) {
            throw "ui:build failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }

    if (-not (Test-Path $controlUiIndex)) {
        throw "Control UI assets still missing after ui:build: $controlUiIndex"
    }
}

[void](Wait-NetworkReady)
Import-OpenClawUserEnvironment
if ([string]::IsNullOrWhiteSpace($env:MINIMAX_API_KEY) -and -not [string]::IsNullOrWhiteSpace($env:OPENCLAW_MINIMAX_API_KEY)) {
    Set-Item -Path 'Env:MINIMAX_API_KEY' -Value $env:OPENCLAW_MINIMAX_API_KEY
}
Stop-RunningGatewayProcesses
Wait-GatewayShutdown
Clear-StaleGatewayLocks
Ensure-ControlUiAssets
& $OpenClawNodeExe $OpenClawDistEntrypoint gateway --port 18789
exit $LASTEXITCODE
