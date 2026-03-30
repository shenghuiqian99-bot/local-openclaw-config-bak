###############################################################################
# OpenClaw ECS SSH 反向隧道脚本
#
# 功能说明:
#   - 通过 SSH 建立反向端口转发隧道
#   - 将远程 ECS 服务器端口映射到本地 Gateway 端口
#   - 支持后台运行和前台交互两种模式
#
# 使用方式:
#   - 后台运行: -RunInBackground
#   - 新窗口运行: -OpenInNewWindow
#   - 交互模式: 直接运行（需要 SSH 密码或密钥）
#
# 隧道参数:
#   - -RemoteGatewayPort: 远程 ECS 监听端口 (默认 28789)
#   - -LocalGatewayPort: 本地 Gateway 端口 (默认 18789)
#   - -ServerHost: ECS 服务器地址
#   - -ServerUser: SSH 用户名
###############################################################################

param(
    [Parameter(Mandatory = $true)]
    [string]$ServerHost,

    [Parameter(Mandatory = $true)]
    [string]$ServerUser,

    [int]$ServerPort = 22,
    [int]$RemoteGatewayPort = 28789,
    [int]$LocalGatewayPort = 18789,
    [string]$KeyPath = '',
    [switch]$RunInBackground,
    [switch]$OpenInNewWindow
)

Set-StrictMode -Version Latest

Write-Host "========================================" -ForegroundColor Green
Write-Host " [start-openclaw-ecs-reverse-tunnel.ps1] OpenClaw ECS Tunnel" -ForegroundColor Green
Write-Host (" Server: {0}@{1}:{2}" -f $ServerUser, $ServerHost, $ServerPort) -ForegroundColor Gray
Write-Host (" Mapping: 127.0.0.1:{0} -> 127.0.0.1:{1}" -f $RemoteGatewayPort, $LocalGatewayPort) -ForegroundColor Gray
if ($RunInBackground) {
    Write-Host " Mode: Background" -ForegroundColor Gray
}
Write-Host " Full Path: $($MyInvocation.MyCommand.Path)" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
$ErrorActionPreference = 'Stop'

$sshExe = (Get-Command ssh.exe -ErrorAction Stop).Source
$target = "$ServerUser@$ServerHost"

if ($RunInBackground -and [string]::IsNullOrWhiteSpace($KeyPath)) {
    throw 'RunInBackground requires SSH key authentication. Password-based SSH cannot be used from a hidden background process or scheduled task.'
}

$portCheck = Test-NetConnection $ServerHost -Port $ServerPort -WarningAction SilentlyContinue
if (-not $portCheck.TcpTestSucceeded) {
    throw "Cannot reach ${ServerHost}:${ServerPort} from this machine. Check the ECS security group, Windows firewall, and OpenSSH Server service before starting the reverse tunnel."
}

function Stop-ExistingTunnel {
    $match = "-R 127.0.0.1:$RemoteGatewayPort`:127.0.0.1:$LocalGatewayPort"
    $existing = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^ssh(\.exe)?$' -and
        $_.CommandLine -like "*$target*" -and
        $_.CommandLine -like "*$match*"
    }

    foreach ($process in $existing) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

$arguments = @(
    '-NT',
    '-o', 'ConnectTimeout=10',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=30',
    '-o', 'ServerAliveCountMax=3',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-p', $ServerPort,
    '-R', "127.0.0.1:$RemoteGatewayPort`:127.0.0.1:$LocalGatewayPort"
)

if ($KeyPath) {
    $resolvedKeyPath = (Resolve-Path -LiteralPath $KeyPath).Path
    $arguments += @('-i', $resolvedKeyPath)
}

$arguments += $target

if (-not (Get-NetTCPConnection -LocalPort $LocalGatewayPort -State Listen -ErrorAction SilentlyContinue)) {
    Write-Warning "Local gateway port $LocalGatewayPort is not listening yet. The tunnel can start now, but Mission Control will stay offline until the local gateway is reachable."
}

Stop-ExistingTunnel

if ($OpenInNewWindow) {
    if ($RunInBackground) {
        throw 'OpenInNewWindow cannot be combined with RunInBackground.'
    }

    $sshArgs = $arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_.Replace('"', '\"')) + '"'
        } else {
            $_
        }
    }

    $command = "& '$sshExe' $($sshArgs -join ' ')"
    Write-Output "Opening a new window for interactive SSH: $target"
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command | Out-Null
    exit 0
}

if ($RunInBackground) {
    $process = Start-Process -FilePath $sshExe -ArgumentList $arguments -PassThru
    Write-Output "Started reverse tunnel in background. PID=$($process.Id) Remote=127.0.0.1:$RemoteGatewayPort Local=127.0.0.1:$LocalGatewayPort"
    exit 0
}

if (-not $KeyPath) {
    Write-Output 'SSH password authentication is expected. Enter the ECS Administrator password when prompted.'
}

Write-Output "Starting reverse tunnel. Remote=127.0.0.1:$RemoteGatewayPort Local=127.0.0.1:$LocalGatewayPort"
& $sshExe @arguments