Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

        if ($property.Name -notmatch '^(OPENCLAW_|OPENAI_|MOONSHOT_|DASHSCOPE_|GEMINI_|ANTHROPIC_|KIMI_|ZAI_|XIAOMI_)') {
            continue
        }

        $value = [string]$property.Value
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        Set-Item -Path ("Env:{0}" -f $property.Name) -Value $value
    }
}

Import-OpenClawUserEnvironment

& openclaw gateway restart
exit $LASTEXITCODE