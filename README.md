# OpenClaw Complete Configuration Backup

This repository contains a **complete backup** of an OpenClaw installation, including everything needed to restore an identical working environment on a new machine.

## What Makes This Backup Complete

This backup includes all configurations that make OpenClaw:
1. **"Know" you** - Your preferences, assistant name, avatar, API configurations
2. **"Understand" you** - Long-term memory (SQLite), session history, learned patterns
3. **"Work for you"** - Skills, agent configurations, scheduled tasks

## Backup Contents

### 1. Core Configuration (`openclaw.json`)
The main configuration file containing:
- Provider configurations (MiniMax, Moonshot, DashScope, OpenAI)
- Model settings for each agent
- UI preferences (assistant name "CC", avatar)
- Secret resolution settings
- Auth profiles

### 2. Agent Configurations (`agents/`)

Each agent has its own configuration that defines how it operates:

| Agent | Path | Purpose |
|-------|------|---------|
| **main** | `agents/main/` | Primary working agent |
| **docs** | `agents/docs/` | Documentation agent |
| **implement** | `agents/implement/` | Implementation agent |
| **logger** | `agents/logger/` | Logger agent |
| **research** | `agents/research/` | Research agent |
| **review** | `agents/review/` | Review agent |

Each agent directory contains:
- `agent/models.json` - Provider and model configuration
- `agent/auth-profiles.json` - Authentication profiles
- `sessions/` - Conversation history (critical for context)

### 3. Long-Term Memory (`memory/`)

**CRITICAL for understanding**: SQLite databases containing:
- `main.sqlite` - Main agent's long-term memory
- `docs.sqlite` - Documentation knowledge
- `implement.sqlite` - Implementation patterns
- `logger.sqlite` - Logger data
- `research.sqlite` - Research memory
- `review.sqlite` - Review patterns

These SQLite files contain learned patterns, accumulated knowledge, and context from past interactions.

### 4. Skills (`.agents/skills/`)

Skill definitions that give OpenClaw its capabilities:
- `ai-automation-workflows/` - Workflow automation skills
- `find-skills/` - Skill discovery
- `self-improving-agent/` - Self-improvement mechanisms
- `skill-creator/` - Skill creation tools
- `skill-vetter/` - Skill validation

### 5. Scheduled Tasks & Scripts

- `gateway-task.ps1` - Core Gateway service (with window visibility fix)
- `start-openclaw-ecs-tunnel-task.ps1` - ECS reverse tunnel
- `scripts/gateway/fix-openclaw-gateway-sleep.ps1` - Sleep recovery
- `scripts/health/install-openclaw-watchdog.ps1` - Health monitoring
- `scripts/health/openclaw-health-check.ps1` - Health check script
- `scripts/tunnel/start-openclaw-ecs-reverse-tunnel.ps1` - SSH tunnel

### 6. Other Configurations

- `settings/` - User preferences (TTS, etc.)
- `cron/` - Scheduled job configurations
- `devices/` - Paired device information
- `feishu/` - Feishu integration settings
- `subagents/` - Subagent run history
- `credentials/` - Feishu credentials
- `task-backups/` - XML backups of Windows scheduled tasks

## Files NOT Included (Sensitive/Environment-Specific)

These are **NOT included** and **MUST be configured manually** after restore:

### Critical (Must Configure)
| File | Reason | How to Configure |
|------|--------|------------------|
| `.env` | API keys, passwords | Create with your API keys |
| `identity/device-auth.json` | Device tokens | Re-authenticate device |

### Optional (Large/Regeneratable)
| File | Size | Notes |
|------|------|-------|
| `memory/*.sqlite.tmp-*` | Temp files | Auto-regenerated |
| `sessions/*.jsonl.reset.*` | Old sessions | Already archived |
| `browser/` | Browser cache | Not needed for restore |
| `workspace*/` | Projects | External to OpenClaw |

## Prerequisites

Before restoring, ensure you have:

1. **OpenClaw installed**:
   ```powershell
   npm install -g openclaw
   ```

2. **PowerShell 5.1+** with execution policy allowing scripts

3. **API Keys** ready:
   - MINIMAX_API_KEY
   - DASHSCOPE_API_KEY
   - MOONSHOT_API_KEY
   - (others as needed)

4. **Git** installed

## One-Click Restore

### Quick Start
```powershell
# Clone this repository
git clone https://github.com/shenghuiqian99-bot/local-openclaw-config-bak.git $env:USERPROFILE\openclaw-backup

# Navigate to backup
cd $env:USERPROFILE\openclaw-backup

# Run one-click restore (with -Force to skip all confirmations)
.\restore-openclaw.ps1 -Force
```

### Restore Script Options
```powershell
.\restore-openclaw.ps1 -Force          # Skip all confirmations
.\restore-openclaw.ps1 -SkipApiKeys     # Skip if .env already exists
.\restore-openclaw.ps1 -SkipScheduledTasks  # Skip task registration
```

## Manual Restore Steps

### 1. Create Directories
```powershell
New-Item -ItemType Directory -Path "$env:USERPROFILE\.openclaw" -Force | Out-Null
New-Item -ItemType Directory -Path "$env:USERPROFILE\.agents" -Force | Out-Null
```

### 2. Copy Files
```powershell
# Core config
Copy-Item -Path "openclaw.json" -Destination "$env:USERPROFILE\.openclaw\" -Force

# Agents
Copy-Item -Path "agents\" -Destination "$env:USERPROFILE\.openclaw\" -Recurse -Force

# Memory (CRITICAL for understanding)
Copy-Item -Path "memory\" -Destination "$env:USERPROFILE\.openclaw\" -Recurse -Force

# Skills
Copy-Item -Path ".agents\skills\" -Destination "$env:USERPROFILE\.agents\" -Recurse -Force

# Settings
Copy-Item -Path "settings\" -Destination "$env:USERPROFILE\.openclaw\" -Recurse -Force
Copy-Item -Path "cron\" -Destination "$env:USERPROFILE\.openclaw\" -Recurse -Force
Copy-Item -Path "devices\" -Destination "$env:USERPROFILE\.openclaw\" -Recurse -Force
Copy-Item -Path "feishu\" -Destination "$env:USERPROFILE\.openclaw\" -Recurse -Force
Copy-Item -Path "subagents\" -Destination "$env:USERPROFILE\.openclaw\" -Recurse -Force
Copy-Item -Path "credentials\" -Destination "$env:USERPROFILE\.openclaw\" -Recurse -Force
```

### 3. Configure API Keys
Create `$env:USERPROFILE\.openclaw\.env`:
```env
MINIMAX_API_KEY=your_minimax_key
DASHSCOPE_API_KEY=your_dashscope_key
MOONSHOT_API_KEY=your_moonshot_key
OPENCLAW_SMTP_HOST=smtp.163.com
OPENCLAW_SMTP_PORT=465
OPENCLAW_SMTP_USERNAME=your_email@163.com
OPENCLAW_SMTP_PASSWORD=your_password
OPENCLAW_SMTP_FROM=your_email@163.com
OPENCLAW_SMTP_USE_SSL=true
```

### 4. Recreate Skills Symlinks
```powershell
$openClawSkills = "$env:USERPROFILE\.openclaw\skills"
$agentsSkills = "$env:USERPROFILE\.agents\skills"

# Remove existing
Remove-Item -Path $openClawSkills -Recurse -Force -ErrorAction SilentlyContinue

# Create junction
cmd /c "mklink /J `"$openClawSkills`" `"$agentsSkills`""
```

### 5. Register Scheduled Tasks
```powershell
# Gateway
powershell.exe -ExecutionPolicy Bypass -File "scripts\gateway\fix-openclaw-gateway-sleep.ps1"

# Watchdog
powershell.exe -ExecutionPolicy Bypass -File "scripts\health\install-openclaw-watchdog.ps1"
```

### 6. Verify
```powershell
openclaw gateway status
openclaw status --deep
```

## Repository Structure

```
local-openclaw-config-bak/
├── .agents/skills/           # Skill definitions
│   ├── ai-automation-workflows/
│   ├── find-skills/
│   ├── self-improving-agent/
│   ├── skill-creator/
│   └── skill-vetter/
├── agents/                   # Agent configurations
│   ├── main/
│   │   ├── agent/           # models.json, auth-profiles.json
│   │   └── sessions/        # Conversation history
│   ├── docs/
│   ├── implement/
│   ├── logger/
│   ├── research/
│   └── review/
├── memory/                   # Long-term memory (SQLite)
│   ├── main.sqlite
│   ├── docs.sqlite
│   ├── implement.sqlite
│   └── ...
├── settings/                 # User settings
├── cron/                     # Scheduled jobs
├── devices/                  # Paired devices
├── feishu/                   # Feishu integration
├── credentials/             # Service credentials
├── scripts/                 # Modified scripts
│   ├── gateway/
│   ├── health/
│   ├── summaries/
│   └── tunnel/
├── task-backups/            # Task XML backups
├── .gitignore
├── README.md
└── restore-openclaw.ps1      # One-click restore
```

## Backup Size

- **Total**: ~283 MB
- **Largest**: Memory SQLite files (~200 MB)
- **After compression**: Significantly smaller with Git LFS recommended

## Backup Maintenance

### Update Backup
```powershell
git clone https://github.com/shenghuiqian99-bot/local-openclaw-config-bak.git
# Make changes to OpenClaw config
git add -A
git commit -m "Backup update: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
git push
```

### Backup Critical Files Only
```powershell
# Backup just the understanding (memory + sessions)
Copy-Item -Path "$env:USERPROFILE\.openclaw\memory" -Destination "backup\memory" -Recurse
Copy-Item -Path "$env:USERPROFILE\.openclaw\agents\main\sessions" -Destination "backup\sessions" -Recurse
```

## Troubleshooting

### Gateway won't start
```powershell
powershell.exe -ExecutionPolicy Bypass -File "scripts\gateway\fix-openclaw-gateway-sleep.ps1"
```

### Memory not working
- Check SQLite files are present in `memory/`
- Verify file permissions

### Skills not loading
- Ensure symlink exists: `$env:USERPROFILE\.openclaw\skills` -> `$env:USERPROFILE\.agents\skills`

## Support

For issues, check:
1. OpenClaw logs: `%LOCALAPPDATA%\Temp\openclaw\`
2. Gateway status: `openclaw gateway status`
3. Deep status: `openclaw status --deep`

## Backup Date
Backup created: 2026-03-30

## Repository
https://github.com/shenghuiqian99-bot/local-openclaw-config-bak
