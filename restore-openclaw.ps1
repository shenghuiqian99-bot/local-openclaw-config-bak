<#
.SYNOPSIS
    One-click restore script for OpenClaw configuration backup

.DESCRIPTION
    This script restores the COMPLETE OpenClaw configuration including:
    - Core configuration (openclaw.json)
    - Agent configurations (all 6 agents)
    - LONG-TERM MEMORY (SQLite databases - critical for understanding)
    - Conversation sessions
    - Skills and capabilities
    - Gateway scripts
    - Settings and credentials

.NOTES
    Run with -Force to skip all confirmation prompts.
    Some operations may require administrator privileges.

.EXAMPLE
    .\restore-openclaw.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipApiKeys,
    [switch]$SkipScheduledTasks
)

$ErrorActionPreference = 'Stop'
$BackupRoot = $PSScriptRoot
$OpenClawHome = Join-Path $env:USERPROFILE '.openclaw'
$AgentsHome = Join-Path $env:USERPROFILE '.agents'

function Write-Banner {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host ""
    Write-Host "========================================" -ForegroundColor $Color
    Write-Host " $Message" -ForegroundColor $Color
    Write-Host "========================================" -ForegroundColor $Color
}

function Write-Step {
    param([string]$Message)
    Write-Host "" -ForegroundColor Cyan
    Write-Host "--- $Message ---" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Gray
}

# Banner
Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host " OpenClaw Complete One-Click Restore" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "Backup Root: $BackupRoot" -ForegroundColor Gray
Write-Host "Target Home: $OpenClawHome" -ForegroundColor Gray
Write-Host ""

# Step 1: Create directories
Write-Banner "Step 1: Creating Directories"

$dirs = @(
    $OpenClawHome,
    $AgentsHome,
    (Join-Path $OpenClawHome 'agents'),
    (Join-Path $OpenClawHome 'agents\main\agent'),
    (Join-Path $OpenClawHome 'agents\main\sessions'),
    (Join-Path $OpenClawHome 'agents\docs\agent'),
    (Join-Path $OpenClawHome 'agents\implement\agent'),
    (Join-Path $OpenClawHome 'agents\logger\agent'),
    (Join-Path $OpenClawHome 'agents\research\agent'),
    (Join-Path $OpenClawHome 'agents\review\agent'),
    (Join-Path $OpenClawHome 'memory'),
    (Join-Path $OpenClawHome 'settings'),
    (Join-Path $OpenClawHome 'cron'),
    (Join-Path $OpenClawHome 'devices'),
    (Join-Path $OpenClawHome 'feishu'),
    (Join-Path $OpenClawHome 'identity'),
    (Join-Path $OpenClawHome 'credentials'),
    (Join-Path $OpenClawHome 'subagents'),
    (Join-Path $OpenClawHome 'skills'),
    (Join-Path $AgentsHome 'skills')
)

foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Info "Created: $dir"
    }
}
Write-Success "Directories ready"

# Step 2: Restore core configuration
Write-Banner "Step 2: Restoring Core Configuration"

$coreFiles = @(
    'openclaw.json',
    'openclaw.json.bak',
    'gateway-task.ps1',
    'gateway.cmd',
    'start-openclaw-ecs-tunnel-task.ps1',
    'openclaw-mission-control-launcher.ps1',
    'mission-control.json',
    'exec-approvals.json',
    'tts-convert-test.json',
    'update-check.json',
    'watchdog-state.json'
)

foreach ($file in $coreFiles) {
    $src = Join-Path $BackupRoot $file
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $OpenClawHome -Force:$Force
        Write-Info "Restored: $file"
    }
}
Write-Success "Core configuration restored"

# Step 3: Restore agents
Write-Banner "Step 3: Restoring Agent Configurations"

$agentDirs = @('main', 'docs', 'implement', 'logger', 'research', 'review')
foreach ($agent in $agentDirs) {
    $src = Join-Path $BackupRoot "agents\$agent"
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $OpenClawHome 'agents') -Recurse -Force:$Force
        Write-Success "Restored: agents\$agent"
    }
}

# Step 4: Restore memory (CRITICAL for understanding)
Write-Banner "Step 4: Restoring LONG-TERM MEMORY (Critical)"

$memorySrc = Join-Path $BackupRoot 'memory'
if (Test-Path $memorySrc) {
    $sqliteFiles = Get-ChildItem -Path $memorySrc -Filter '*.sqlite' -ErrorAction SilentlyContinue
    foreach ($file in $sqliteFiles) {
        Copy-Item -Path $file.FullName -Destination (Join-Path $OpenClawHome 'memory') -Force:$Force
        Write-Info "Restored: $($file.Name) ($(('{0:N2}' -f ($file.Length / 1MB))) MB)"
    }
    Write-Success "Memory databases restored"
    Write-Warning "Memory files are CRITICAL for OpenClaw to remember and understand you!"
} else {
    Write-Warning "Memory directory not found in backup"
}

# Step 5: Restore skills
Write-Banner "Step 5: Restoring Skills"

$skillsSrc = Join-Path $BackupRoot '.agents\skills'
if (Test-Path $skillsSrc) {
    Copy-Item -Path $skillsSrc -Destination $AgentsHome -Recurse -Force:$Force
    $skills = Get-ChildItem -Path $skillsSrc -Directory
    foreach ($skill in $skills) {
        Write-Info "Restored: $($skill.Name)"
    }
    Write-Success "Skills restored"
}

# Step 6: Restore settings and other configs
Write-Banner "Step 6: Restoring Settings & Configurations"

$configDirs = @('settings', 'cron', 'devices', 'feishu', 'identity', 'subagents', 'credentials')
foreach ($dir in $configDirs) {
    $src = Join-Path $BackupRoot $dir
    $dst = Join-Path $OpenClawHome $dir
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $OpenClawHome -Recurse -Force:$Force
        Write-Success "Restored: $dir"
    }
}

# Step 7: Restore scripts
Write-Banner "Step 7: Restoring Scripts"

$scriptsSrc = Join-Path $BackupRoot 'scripts'
if (Test-Path $scriptsSrc) {
    Copy-Item -Path $scriptsSrc -Destination $BackupRoot -Recurse -Force:$Force
    Write-Success "Scripts restored"
}

# Step 8: Restore task backups
Write-Banner "Step 8: Restoring Task Backups"

$taskBackupSrc = Join-Path $BackupRoot 'task-backups'
if (Test-Path $taskBackupSrc) {
    New-Item -ItemType Directory -Path (Join-Path $OpenClawHome 'task-backups') -Force | Out-Null
    Copy-Item -Path "$taskBackupSrc\*" -Destination (Join-Path $OpenClawHome 'task-backups') -Force:$Force
    $tasks = Get-ChildItem -Path $taskBackupSrc -Filter '*.xml'
    foreach ($task in $tasks) {
        Write-Info "Backed up: $($task.Name)"
    }
    Write-Success "Task backups restored"
}

# Step 9: Recreate skills symlink
Write-Banner "Step 9: Recreating Skills Symlink"

$openClawSkills = Join-Path $OpenClawHome 'skills'
$agentsSkills = Join-Path $AgentsHome 'skills'

# Remove existing junction/symlink if exists
if (Test-Path $openClawSkills) {
    Remove-Item -Path $openClawSkills -Force -ErrorAction SilentlyContinue
}

try {
    # Create junction (doesn't require admin)
    $result = cmd /c "mklink /J `"$openClawSkills`" `"$agentsSkills`" 2>&1"
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Created junction: $openClawSkills -> $agentsSkills"
    } else {
        throw "Junction creation failed"
    }
} catch {
    Write-Warning "Could not create junction. Manually run:"
    Write-Info "cmd /c `"mklink /J `"$openClawSkills`" `"$agentsSkills`""
}

# Step 10: Create .env template
Write-Banner "Step 10: Environment Configuration"

$envFile = Join-Path $OpenClawHome '.env'
$envTemplate = @"
# OpenClaw Environment Configuration
# =========================================
# Copy this file to: $envFile
# AND FILL IN YOUR API KEYS!

# API Keys (REQUIRED - without these, OpenClaw won't work)
MINIMAX_API_KEY=your_minimax_api_key_here
DASHSCOPE_API_KEY=your_dashscope_api_key_here
MOONSHOT_API_KEY=your_moonshot_api_key_here
OPENAI_API_KEY=

# SMTP Settings (optional - for email notifications)
OPENCLAW_SMTP_HOST=smtp.163.com
OPENCLAW_SMTP_PORT=465
OPENCLAW_SMTP_USERNAME=your_email@163.com
OPENCLAW_SMTP_PASSWORD=your_smtp_password
OPENCLAW_SMTP_FROM=your_email@163.com
OPENCLAW_SMTP_USE_SSL=true

# Additional API Keys (uncomment as needed)
# ANTHROPIC_API_KEY=
# KIMI_API_KEY=
"@

if (Test-Path $envFile) {
    Write-Warning ".env already exists, skipped"
} else {
    Set-Content -Path $envFile -Value $envTemplate -Encoding UTF8
    Write-Success "Created .env template at: $envFile"
    Write-Warning "IMPORTANT: Edit this file and add your API keys!"
}

# Step 11: Register scheduled tasks
Write-Banner "Step 11: Registering Scheduled Tasks"

if ($SkipScheduledTasks) {
    Write-Warning "Skipped scheduled task registration"
} else {
    $taskScripts = @(
        @{Script='scripts\gateway\fix-openclaw-gateway-sleep.ps1'; Name='OpenClaw Gateway'},
        @{Script='scripts\health\install-openclaw-watchdog.ps1'; Name='OpenClaw Watchdog'}
    )

    foreach ($task in $taskScripts) {
        $scriptPath = Join-Path $BackupRoot $task.Script
        if (Test-Path $scriptPath) {
            try {
                Write-Info "Registering: $($task.Name)..."
                $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "Registered: $($task.Name)"
                } else {
                    Write-Warning "Registration may have issues: $($task.Name)"
                    Write-Info $output
                }
            } catch {
                Write-Warning "Could not register: $($task.Name) - $_"
            }
        }
    }
}

# Final Summary
Write-Banner "Restore Complete!"

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " IMPORTANT: Next Steps" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. EDIT .ENV FILE AND ADD YOUR API KEYS:" -ForegroundColor White
Write-Host "   notepad.exe $envFile" -ForegroundColor Gray
Write-Host ""
Write-Host "2. VERIFY OPENCLAW IS WORKING:" -ForegroundColor White
Write-Host "   openclaw gateway status" -ForegroundColor Gray
Write-Host "   openclaw status --deep" -ForegroundColor Gray
Write-Host ""
Write-Host "3. IF TASKS WERE NOT REGISTERED, RUN MANUALLY:" -ForegroundColor White
$taskPath = Join-Path $BackupRoot 'scripts\gateway\fix-openclaw-gateway-sleep.ps1'
Write-Host "   powershell.exe -ExecutionPolicy Bypass -File `"$taskPath`"" -ForegroundColor Gray
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "RESTORED COMPONENTS:" -ForegroundColor White
Write-Host "  - Core configuration (openclaw.json)" -ForegroundColor Gray
Write-Host "  - Agent configurations (6 agents)" -ForegroundColor Gray
Write-Host "  - LONG-TERM MEMORY (SQLite databases)" -ForegroundColor Gray
Write-Host "  - Skills and capabilities" -ForegroundColor Gray
Write-Host "  - Gateway and tunnel scripts" -ForegroundColor Gray
Write-Host "  - Settings and credentials" -ForegroundColor Gray
Write-Host ""
