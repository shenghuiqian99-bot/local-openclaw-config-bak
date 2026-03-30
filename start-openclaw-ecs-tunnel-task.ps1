###############################################################################
# OpenClaw ECS 反向隧道启动脚本
#
# 功能说明:
#   - 建立本地 Gateway 到阿里云 ECS 的反向 SSH 隧道
#   - 将本地 18789 端口映射到远程 ECS 的 28789 端口
#   - 使外部网络可以通过 ECS 访问本地 Gateway 服务
#
# 启动方式:
#   - Windows 定时任务 "OpenClaw ECS Reverse Tunnel" 自动触发
#   - 使用 SSH 密钥认证，后台静默运行
#
# 连接信息:
#   - 服务器: 8.136.214.164:22
#   - 用户: Administrator
#   - 远程端口: 127.0.0.1:28789
#   - 本地端口: 127.0.0.1:18789
###############################################################################

Write-Host "========================================" -ForegroundColor Green
Write-Host " [start-openclaw-ecs-tunnel-task.ps1] OpenClaw ECS" -ForegroundColor Green
Write-Host " Server: 8.136.214.164:22" -ForegroundColor Gray
Write-Host " Mapping: 28789 -> 18789 (local)" -ForegroundColor Gray
Write-Host " Full Path: $($MyInvocation.MyCommand.Path)" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& 'E:\projects\clawbot\scripts\start-openclaw-ecs-reverse-tunnel.ps1' -ServerHost '8.136.214.164' -ServerUser 'Administrator' -ServerPort 22 -RemoteGatewayPort 28789 -LocalGatewayPort 18789 -KeyPath 'C:\Users\RickQ\.ssh\openclaw-ecs' -RunInBackground
