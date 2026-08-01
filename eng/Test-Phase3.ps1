[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pipelinePath = [IO.Path]::Combine($repoRoot, 'pipelines', 'drift-report.yml')
$scriptPath = Join-Path $PSScriptRoot 'New-DatabaseDriftReport.ps1'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

foreach ($path in @($pipelinePath, $scriptPath)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Required Phase 3 file not found: $path"
    }
}

$pipelineText = Get-Content -Path $pipelinePath -Raw
$scriptText = Get-Content -Path $scriptPath -Raw
$actionPattern = '(?i)/Action:(?<action>[A-Za-z]+)'
$actions = @(
    [regex]::Matches("$pipelineText`n$scriptText", $actionPattern) |
        ForEach-Object { $_.Groups['action'].Value }
)
Assert-True ($actions.Count -gt 0) 'The drift path must invoke an explicit SqlPackage action.'
Assert-True (@($actions | Where-Object { $_ -ne 'DeployReport' }).Count -eq 0) 'The drift path may invoke only /Action:DeployReport.'
Assert-True ($pipelineText -match "(?m)^\s*-\s*cron:\s*'0 2 \* \* \*'\s*$") 'The daily 02:00 UTC schedule is missing.'
Assert-True ($pipelineText -match 'AzureCLI@2') 'The drift pipeline must use the existing WIF AzureCLI task pattern.'
Assert-True ($pipelineText -match 'driftDetected') 'Drift artifact publication must be conditional on detected changes.'
Assert-True ($scriptText -match 'SucceededWithIssues') 'Detected drift must mark the task SucceededWithIssues.'
Assert-True ($scriptText -match 'Resolve-DatabaseNames') 'The representative database policy must reuse validated database resolution.'
Assert-True ($scriptText -notmatch '(?i)\bDeploy-Databases\b|\bDeploy-InstanceObjects\b') 'The drift path must not call deployment scripts.'

Write-Host 'All Phase 3 drift pipeline static safety tests passed.'
