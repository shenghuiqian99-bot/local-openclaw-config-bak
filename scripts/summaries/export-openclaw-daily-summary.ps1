param(
    [string]$TargetDate,
    [string]$StateDir,
    [string]$SessionsSummaryFolderName = 'daily-reports',
    [string]$MemoryDigestFolderName = 'auto-digests',
    [switch]$CurrentDay,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OpenClawStateDir {
    param([string]$ExplicitStateDir)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitStateDir)) {
        return $ExplicitStateDir
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OPENCLAW_STATE_DIR)) {
        return $env:OPENCLAW_STATE_DIR
    }

    return (Join-Path $env:USERPROFILE '.openclaw')
}

function Get-TargetDay {
    param(
        [string]$ExplicitDay,
        [switch]$UseCurrentDay
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitDay)) {
        return ([datetime]::Parse($ExplicitDay)).ToString('yyyy-MM-dd')
    }

    if ($UseCurrentDay) {
        return (Get-Date).ToString('yyyy-MM-dd')
    }

    return (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
}

function Convert-ToLocalDay {
    param([string]$Timestamp)

    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        return $null
    }

    try {
        return ([DateTimeOffset]::Parse($Timestamp).ToLocalTime()).ToString('yyyy-MM-dd')
    } catch {
        return $null
    }
}

function Convert-ToLocalTimeDisplay {
    param([string]$Timestamp)

    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        return 'unknown'
    }

    try {
        return ([DateTimeOffset]::Parse($Timestamp).ToLocalTime()).ToString('MM-dd HH:mm')
    } catch {
        return $Timestamp
    }
}

function Get-TextFromContent {
    param($Content)

    if ($null -eq $Content) {
        return ''
    }

    if ($Content -is [string]) {
        return $Content.Trim()
    }

    if ($Content -is [System.Collections.IEnumerable] -and -not ($Content -is [string])) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($block in $Content) {
            if ($block -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($block)) {
                    $parts.Add($block.Trim())
                }
                continue
            }

            if ($null -eq $block) {
                continue
            }

            $type = $block.type
            if ($type -eq 'text' -and -not [string]::IsNullOrWhiteSpace($block.text)) {
                $parts.Add([string]$block.text)
                continue
            }

            if ($type -eq 'toolCall') {
                $toolName = if ($block.name) { [string]$block.name } else { 'tool' }
                $arguments = if ($block.arguments) { ($block.arguments | ConvertTo-Json -Depth 8) } else { '' }
                $parts.Add("[Tool call] $toolName" + ($(if ($arguments) { "`n$arguments" } else { '' })))
                continue
            }

            if ($type -eq 'toolResult') {
                $toolName = if ($block.toolName) { [string]$block.toolName } else { 'tool' }
                $toolResultText = Get-TextFromContent -Content $block.content
                $parts.Add("[Tool result] $toolName" + ($(if ($toolResultText) { "`n$toolResultText" } else { '' })))
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($block.text)) {
                $parts.Add([string]$block.text)
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($block.content)) {
                $parts.Add([string]$block.content)
            }
        }

        return (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n`n").Trim()
    }

    if ($Content.PSObject.Properties.Match('text').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Content.text)) {
        return [string]$Content.text
    }

    return ''
}

function Get-ClippedText {
    param(
        [string]$Text,
        [int]$MaxLength = 240
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $flat = ($Text -replace '\s+', ' ').Trim()
    if ($flat.Length -le $MaxLength) {
        return $flat
    }

    return ($flat.Substring(0, $MaxLength) + '...')
}

function Add-UniqueItem {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $normalized = $Value.Trim()
    if (-not ($List.Contains($normalized))) {
        $List.Add($normalized)
    }
}

function Get-SignalCandidates {
    param(
        [string[]]$Texts,
        [string]$Pattern,
        [int]$Limit = 8
    )

    $results = New-Object System.Collections.Generic.List[string]
    foreach ($text in $Texts) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($text -match $Pattern) {
            Add-UniqueItem -List $results -Value (Get-ClippedText -Text $text -MaxLength 240)
        }

        if ($results.Count -ge $Limit) {
            break
        }
    }

    return $results
}

function Test-MemoryRelevantSession {
    param(
        [string]$Title,
        [string[]]$UserTexts,
        [string[]]$AssistantTexts
    )

    $combined = (@($Title) + @($UserTexts) + @($AssistantTexts)) -join " `n"
    if ([string]::IsNullOrWhiteSpace($combined)) {
        return $false
    }

    if ($Title -match '^\[cron:' -or $Title -match '^Conversation info \(untrusted metadata\)') {
        return $false
    }

    if ($combined -match '(?i)untrusted metadata|health.?check|heartbeat|scheduled task|cron trigger|system ping|gateway status') {
        return $false
    }

    if ((@($UserTexts).Count -eq 0) -and (@($AssistantTexts).Count -le 1)) {
        return $false
    }

    return $true
}

function Split-JsonObjectStream {
    param([string]$Raw)

    $objects = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return @($objects.ToArray())
    }

    $builder = New-Object System.Text.StringBuilder
    $depth = 0
    $inString = $false
    $escaping = $false

    foreach ($character in $Raw.ToCharArray()) {
        if ($depth -eq 0 -and [char]::IsWhiteSpace($character)) {
            continue
        }

        [void]$builder.Append($character)

        if ($escaping) {
            $escaping = $false
            continue
        }

        if ($character -eq '\\') {
            $escaping = $true
            continue
        }

        if ($character -eq '"') {
            $inString = -not $inString
            continue
        }

        if ($inString) {
            continue
        }

        if ($character -eq '{') {
            $depth += 1
            continue
        }

        if ($character -eq '}') {
            $depth -= 1
            if ($depth -eq 0) {
                $objects.Add($builder.ToString())
                $builder.Clear() | Out-Null
            }
        }
    }

    return @($objects.ToArray())
}

function Read-JsonlTranscript {
    param([string]$Path)

    $items = New-Object System.Collections.Generic.List[object]
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop

    foreach ($line in Split-JsonObjectStream -Raw $raw) {
        try {
            $items.Add(($line | ConvertFrom-Json -ErrorAction Stop))
        } catch {
            continue
        }
    }

    return @($items.ToArray())
}

function Get-SessionSummary {
    param(
        [string]$AgentId,
        [string]$TranscriptPath,
        [string]$Day
    )

    $entries = @(Read-JsonlTranscript -Path $TranscriptPath)
    if ($entries.Count -eq 0) {
        return $null
    }

    $sessionEntry = $entries | Where-Object { $_.type -eq 'session' } | Select-Object -First 1
    $messageEntries = @($entries | Where-Object { $_.type -eq 'message' })
    if ($messageEntries.Count -eq 0) {
        return $null
    }

    $startedAt = if ($sessionEntry -and $sessionEntry.timestamp) { [string]$sessionEntry.timestamp } else { [string]$messageEntries[0].timestamp }
    $localDay = Convert-ToLocalDay -Timestamp $startedAt
    if ($localDay -ne $Day) {
        return $null
    }

    $endedAt = [string]$messageEntries[-1].timestamp
    $userTexts = New-Object System.Collections.Generic.List[string]
    $assistantTexts = New-Object System.Collections.Generic.List[string]
    $tools = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $messageEntries) {
        $message = $entry.message
        if ($null -eq $message) {
            continue
        }

        $role = [string]$message.role
        $text = Get-TextFromContent -Content $message.content
        if ($role -eq 'user') {
            Add-UniqueItem -List $userTexts -Value $text
        } elseif ($role -eq 'assistant') {
            Add-UniqueItem -List $assistantTexts -Value $text
            if ($message.content -is [System.Collections.IEnumerable]) {
                foreach ($block in $message.content) {
                    if ($null -ne $block -and $block.type -eq 'toolCall' -and -not [string]::IsNullOrWhiteSpace($block.name)) {
                        Add-UniqueItem -List $tools -Value ([string]$block.name)
                    }
                }
            }
        } elseif ($role -eq 'toolResult' -and -not [string]::IsNullOrWhiteSpace($message.toolName)) {
            Add-UniqueItem -List $tools -Value ([string]$message.toolName)
        }
    }

    $title = if ($userTexts.Count -gt 0) { Get-ClippedText -Text $userTexts[0] -MaxLength 120 } else { [IO.Path]::GetFileNameWithoutExtension($TranscriptPath) }
    $signalTexts = @($userTexts + $assistantTexts)
    $memoryRelevant = Test-MemoryRelevantSession -Title $title -UserTexts @($userTexts.ToArray()) -AssistantTexts @($assistantTexts.ToArray())

    $preferenceSignals = @(Get-SignalCandidates -Texts $signalTexts -Pattern '(需要|要求|不要|必须|希望|记住|以后|优先|中文|英文|偏好|习惯|风格|prefer|always|never|remember|must|avoid|should|use|格式|界面|显示)' -Limit 10)
    $followUpSignals = @(Get-SignalCandidates -Texts $signalTexts -Pattern '(待办|todo|继续|后续|补充|下一步|next step|follow[- ]?up|完成|补全|接入|联调|验证|检查|优化|增强|修正|排查)' -Limit 10)
    $decisionSignals = @(Get-SignalCandidates -Texts $signalTexts -Pattern '(决定|采用|改成|切换|修复|策略|fix|fallback|stable|默认|方案|改为|落地|实现|直接显示|保存在|自动生成)' -Limit 10)
    $topicSignals = @(Get-SignalCandidates -Texts $signalTexts -Pattern '(mission control|logs|summary|daily report|memory|session|skill|gateway|agent|archive|日历|总结|提炼|记忆|会话|日志|配置|脚本|任务计划)' -Limit 12)

    return [pscustomobject]@{
        AgentId = $AgentId
        Title = $title
        TranscriptPath = $TranscriptPath
        TranscriptName = [IO.Path]::GetFileName($TranscriptPath)
        StartedAt = $startedAt
        EndedAt = $endedAt
        StartedAtDisplay = Convert-ToLocalTimeDisplay -Timestamp $startedAt
        EndedAtDisplay = Convert-ToLocalTimeDisplay -Timestamp $endedAt
        MessageCount = $messageEntries.Count
        UserCount = @($messageEntries | Where-Object { $_.message.role -eq 'user' }).Count
        AssistantCount = @($messageEntries | Where-Object { $_.message.role -eq 'assistant' -or $_.message.role -eq 'toolResult' }).Count
        UserTexts = @($userTexts.ToArray())
        AssistantTexts = @($assistantTexts.ToArray())
        Tools = @($tools.ToArray())
        MemoryRelevant = $memoryRelevant
        PreferenceSignals = $preferenceSignals
        FollowUpSignals = $followUpSignals
        DecisionSignals = $decisionSignals
        TopicSignals = $topicSignals
    }
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Build-AgentReport {
    param(
        [string]$Day,
        [string]$AgentId,
        [object[]]$Sessions
    )

    $meaningfulSessions = @($Sessions | Where-Object { $_.MemoryRelevant })
    $reportSessions = if ($meaningfulSessions.Count -gt 0) { $meaningfulSessions } else { $Sessions }
    $totalMessages = ($reportSessions | Measure-Object -Property MessageCount -Sum).Sum
    $totalUserMessages = ($reportSessions | Measure-Object -Property UserCount -Sum).Sum
    $totalAssistantMessages = ($reportSessions | Measure-Object -Property AssistantCount -Sum).Sum
    $toolBag = New-Object System.Collections.Generic.List[string]
    $topicBag = New-Object System.Collections.Generic.List[string]
    $preferenceBag = New-Object System.Collections.Generic.List[string]
    $decisionBag = New-Object System.Collections.Generic.List[string]
    $followUpBag = New-Object System.Collections.Generic.List[string]
    foreach ($session in $reportSessions) {
        foreach ($tool in @($session.Tools)) {
            Add-UniqueItem -List $toolBag -Value $tool
        }
        foreach ($item in @($session.TopicSignals)) {
            Add-UniqueItem -List $topicBag -Value $item
        }
        foreach ($item in @($session.PreferenceSignals)) {
            Add-UniqueItem -List $preferenceBag -Value $item
        }
        foreach ($item in @($session.DecisionSignals)) {
            Add-UniqueItem -List $decisionBag -Value $item
        }
        foreach ($item in @($session.FollowUpSignals)) {
            Add-UniqueItem -List $followUpBag -Value $item
        }
    }
    $toolList = @($toolBag.ToArray() | Sort-Object -Unique)
    $report = New-Object System.Text.StringBuilder

    [void]$report.AppendLine("# Daily Conversation Report - $Day")
    [void]$report.AppendLine()
    [void]$report.AppendLine("- Agent: $AgentId")
    [void]$report.AppendLine("- GeneratedAt: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
    [void]$report.AppendLine("- Sessions: $($reportSessions.Count)")
    [void]$report.AppendLine("- IgnoredNoiseSessions: $(($Sessions.Count - $reportSessions.Count))")
    [void]$report.AppendLine("- Messages: $totalMessages")
    [void]$report.AppendLine("- UserMessages: $totalUserMessages")
    [void]$report.AppendLine("- AssistantOrToolMessages: $totalAssistantMessages")
    [void]$report.AppendLine("- Tools: $(if ($toolList) { $toolList -join ', ' } else { 'none' })")
    [void]$report.AppendLine()
    [void]$report.AppendLine('## Daily Highlights')
    [void]$report.AppendLine()
    [void]$report.AppendLine('### Core Topics')
    foreach ($item in ($topicBag | Select-Object -First 8)) {
        [void]$report.AppendLine("- $item")
    }
    if ($topicBag.Count -eq 0) {
        [void]$report.AppendLine('- No stable topics extracted.')
    }
    [void]$report.AppendLine()
    [void]$report.AppendLine('### Stable Preferences And Constraints')
    foreach ($item in ($preferenceBag | Select-Object -First 8)) {
        [void]$report.AppendLine("- $item")
    }
    if ($preferenceBag.Count -eq 0) {
        [void]$report.AppendLine('- No stable preferences extracted.')
    }
    [void]$report.AppendLine()
    [void]$report.AppendLine('### Decisions')
    foreach ($item in ($decisionBag | Select-Object -First 8)) {
        [void]$report.AppendLine("- $item")
    }
    if ($decisionBag.Count -eq 0) {
        [void]$report.AppendLine('- No explicit decisions extracted.')
    }
    [void]$report.AppendLine()
    [void]$report.AppendLine('### Follow Ups')
    foreach ($item in ($followUpBag | Select-Object -First 8)) {
        [void]$report.AppendLine("- $item")
    }
    if ($followUpBag.Count -eq 0) {
        [void]$report.AppendLine('- No follow-ups extracted.')
    }
    [void]$report.AppendLine()
    [void]$report.AppendLine('## Session Timeline')
    [void]$report.AppendLine()

    foreach ($session in $reportSessions) {
        [void]$report.AppendLine("### $($session.StartedAtDisplay) - $($session.Title)")
        [void]$report.AppendLine("- Transcript: $($session.TranscriptName)")
        [void]$report.AppendLine("- TimeRange: $($session.StartedAtDisplay) to $($session.EndedAtDisplay)")
        [void]$report.AppendLine("- MessageCount: $($session.MessageCount)")
        [void]$report.AppendLine("- UserGoal: $(if ($session.UserTexts.Count -gt 0) { Get-ClippedText -Text $session.UserTexts[0] -MaxLength 260 } else { 'n/a' })")
        [void]$report.AppendLine("- Outcome: $(if ($session.AssistantTexts.Count -gt 0) { Get-ClippedText -Text $session.AssistantTexts[0] -MaxLength 260 } else { 'n/a' })")
        [void]$report.AppendLine("- Tools: $(if ($session.Tools.Count -gt 0) { $session.Tools -join ', ' } else { 'none' })")

        if ($session.FollowUpSignals.Count -gt 0) {
            [void]$report.AppendLine('- FollowUps:')
            foreach ($item in $session.FollowUpSignals | Select-Object -First 3) {
                [void]$report.AppendLine("  - $item")
            }
        }

        if ($session.DecisionSignals.Count -gt 0) {
            [void]$report.AppendLine('- Decisions:')
            foreach ($item in $session.DecisionSignals | Select-Object -First 3) {
                [void]$report.AppendLine("  - $item")
            }
        }

        [void]$report.AppendLine()
    }

    return $report.ToString().TrimEnd()
}

function Build-MemoryDigest {
    param(
        [string]$Day,
        [object[]]$AllSessions,
        [string[]]$ReportPaths
    )

    $preferences = New-Object System.Collections.Generic.List[string]
    $followUps = New-Object System.Collections.Generic.List[string]
    $decisions = New-Object System.Collections.Generic.List[string]
    $projects = New-Object System.Collections.Generic.List[string]
    $topics = New-Object System.Collections.Generic.List[string]
    $tools = New-Object System.Collections.Generic.List[string]

    foreach ($session in $AllSessions | Where-Object { $_.MemoryRelevant }) {
        Add-UniqueItem -List $projects -Value $session.Title
        foreach ($item in $session.TopicSignals) { Add-UniqueItem -List $topics -Value $item }
        foreach ($item in $session.PreferenceSignals) { Add-UniqueItem -List $preferences -Value $item }
        foreach ($item in $session.FollowUpSignals) { Add-UniqueItem -List $followUps -Value $item }
        foreach ($item in $session.DecisionSignals) { Add-UniqueItem -List $decisions -Value $item }
        foreach ($item in $session.Tools) { Add-UniqueItem -List $tools -Value $item }
    }

    $content = New-Object System.Text.StringBuilder
    [void]$content.AppendLine("# Auto Memory Digest - $Day")
    [void]$content.AppendLine()
    [void]$content.AppendLine('This file is auto-generated from OpenClaw session transcripts and is intended to improve retrieval from the memory workspace.')
    [void]$content.AppendLine()
    [void]$content.AppendLine('## Core Topics')
    foreach ($item in ($topics | Select-Object -First 15)) {
        [void]$content.AppendLine("- $item")
    }
    if ($topics.Count -eq 0) {
        [void]$content.AppendLine('- No core topics extracted.')
    }
    [void]$content.AppendLine()
    [void]$content.AppendLine('## Stable User Signals')
    foreach ($item in ($preferences | Select-Object -First 15)) {
        [void]$content.AppendLine("- $item")
    }
    if ($preferences.Count -eq 0) {
        [void]$content.AppendLine('- No stable preference signals extracted.')
    }
    [void]$content.AppendLine()
    [void]$content.AppendLine('## Active Goals')
    foreach ($item in ($projects | Select-Object -First 12)) {
        [void]$content.AppendLine("- $item")
    }
    if ($projects.Count -eq 0) {
        [void]$content.AppendLine('- No active goals extracted.')
    }
    [void]$content.AppendLine()
    [void]$content.AppendLine('## Decisions And Constraints')
    foreach ($item in ($decisions | Select-Object -First 12)) {
        [void]$content.AppendLine("- $item")
    }
    if ($decisions.Count -eq 0) {
        [void]$content.AppendLine('- No explicit decisions extracted.')
    }
    [void]$content.AppendLine()
    [void]$content.AppendLine('## Open Follow Ups')
    foreach ($item in ($followUps | Select-Object -First 15)) {
        [void]$content.AppendLine("- $item")
    }
    if ($followUps.Count -eq 0) {
        [void]$content.AppendLine('- No open follow-ups extracted.')
    }
    [void]$content.AppendLine()
    [void]$content.AppendLine('## Tools Used')
    foreach ($item in ($tools | Select-Object -First 20)) {
        [void]$content.AppendLine("- $item")
    }
    if ($tools.Count -eq 0) {
        [void]$content.AppendLine('- No tools detected.')
    }
    [void]$content.AppendLine()
    [void]$content.AppendLine('## Source Reports')
    foreach ($path in $ReportPaths) {
        [void]$content.AppendLine("- $path")
    }

    return [pscustomobject]@{
        Content = $content.ToString().TrimEnd()
        Topics = $topics
        Preferences = $preferences
        Projects = $projects
        Decisions = $decisions
        FollowUps = $followUps
    }
}

function Build-RollingUserProfile {
    param(
        [string]$Day,
        [pscustomobject]$Digest
    )

    $content = New-Object System.Text.StringBuilder
    [void]$content.AppendLine('# USER_PROFILE.auto')
    [void]$content.AppendLine()
    [void]$content.AppendLine('Auto-generated rolling memory profile from recent daily session digests.')
    [void]$content.AppendLine("LastUpdated: $Day")
    [void]$content.AppendLine()
    [void]$content.AppendLine('## Core Topics')
    foreach ($item in ($Digest.Topics | Select-Object -First 20)) {
        [void]$content.AppendLine("- $item")
    }
    if ($Digest.Topics.Count -eq 0) {
        [void]$content.AppendLine('- No core topics extracted yet.')
    }
    [void]$content.AppendLine()
    [void]$content.AppendLine('## Preferences')
    foreach ($item in ($Digest.Preferences | Select-Object -First 20)) {
        [void]$content.AppendLine("- $item")
    }
    if ($Digest.Preferences.Count -eq 0) {
        [void]$content.AppendLine('- No stable preferences extracted yet.')
    }
    [void]$content.AppendLine()
    [void]$content.AppendLine('## Current Goals')
    foreach ($item in ($Digest.Projects | Select-Object -First 20)) {
        [void]$content.AppendLine("- $item")
    }
    if ($Digest.Projects.Count -eq 0) {
        [void]$content.AppendLine('- No current goals extracted yet.')
    }
    [void]$content.AppendLine()
    [void]$content.AppendLine('## Follow Ups')
    foreach ($item in ($Digest.FollowUps | Select-Object -First 20)) {
        [void]$content.AppendLine("- $item")
    }
    if ($Digest.FollowUps.Count -eq 0) {
        [void]$content.AppendLine('- No follow-ups extracted yet.')
    }

    return $content.ToString().TrimEnd()
}

$resolvedStateDir = Get-OpenClawStateDir -ExplicitStateDir $StateDir
$day = Get-TargetDay -ExplicitDay $TargetDate -UseCurrentDay:$CurrentDay
$agentsDir = Join-Path $resolvedStateDir 'agents'
$workspaceMemoryDir = Join-Path $resolvedStateDir 'workspace\memory'
$memoryDigestDir = Join-Path $workspaceMemoryDir $MemoryDigestFolderName

if (-not (Test-Path -LiteralPath $agentsDir)) {
    throw "Agents directory not found: $agentsDir"
}

if (-not (Test-Path -LiteralPath $workspaceMemoryDir)) {
    New-Item -ItemType Directory -Path $workspaceMemoryDir -Force | Out-Null
}

$agentDirectories = Get-ChildItem -LiteralPath $agentsDir -Directory | Sort-Object Name
$allSessions = New-Object System.Collections.Generic.List[object]
$writtenReports = New-Object System.Collections.Generic.List[string]

foreach ($agentDirectory in $agentDirectories) {
    $sessionsDir = Join-Path $agentDirectory.FullName 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsDir)) {
        continue
    }

    $transcripts = Get-ChildItem -LiteralPath $sessionsDir -File | Where-Object {
        $_.Name -match '\.jsonl($|\.)' -and
        $_.Name -notmatch '\.deleted\.' -and
        $_.Name -notmatch '\.reset\.'
    }

    $sessionSummaries = New-Object System.Collections.Generic.List[object]
    foreach ($transcript in $transcripts) {
        $summary = Get-SessionSummary -AgentId $agentDirectory.Name -TranscriptPath $transcript.FullName -Day $day
        if ($null -ne $summary) {
            $sessionSummaries.Add($summary)
            $allSessions.Add($summary)
        }
    }

    if ($sessionSummaries.Count -eq 0) {
        continue
    }

    $sortedSessions = @($sessionSummaries | Sort-Object StartedAt)
    $reportDir = Join-Path $sessionsDir $SessionsSummaryFolderName
    $reportPath = Join-Path $reportDir "$day.md"
    if ($Force -or -not (Test-Path -LiteralPath $reportPath)) {
        $reportContent = Build-AgentReport -Day $day -AgentId $agentDirectory.Name -Sessions $sortedSessions
        Write-Utf8File -Path $reportPath -Content $reportContent
    } else {
        $reportContent = Build-AgentReport -Day $day -AgentId $agentDirectory.Name -Sessions $sortedSessions
        Write-Utf8File -Path $reportPath -Content $reportContent
    }
    Add-UniqueItem -List $writtenReports -Value $reportPath
}

if ($allSessions.Count -eq 0) {
    Write-Output (@{
        ok = $true
        day = $day
        message = 'No transcripts found for target day.'
        reportCount = 0
        memoryDigest = $null
    } | ConvertTo-Json -Depth 6)
    return
}

$digest = Build-MemoryDigest -Day $day -AllSessions @($allSessions | Sort-Object StartedAt) -ReportPaths @($writtenReports)
$memoryDigestPath = Join-Path $memoryDigestDir "$day.md"
Write-Utf8File -Path $memoryDigestPath -Content $digest.Content

$rollingProfilePath = Join-Path $workspaceMemoryDir 'USER_PROFILE.auto.md'
Write-Utf8File -Path $rollingProfilePath -Content (Build-RollingUserProfile -Day $day -Digest $digest)

Write-Output (@{
    ok = $true
    day = $day
    stateDir = $resolvedStateDir
    reportCount = $writtenReports.Count
    reports = @($writtenReports)
    memoryDigest = $memoryDigestPath
    rollingProfile = $rollingProfilePath
    sessionCount = $allSessions.Count
} | ConvertTo-Json -Depth 6)