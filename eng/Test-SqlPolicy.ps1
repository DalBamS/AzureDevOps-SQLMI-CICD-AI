[CmdletBinding()]
param(
    [string]$SourcePath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $SourcePath) {
    $SourcePath = [IO.Path]::Combine($repoRoot, 'database', 'App.Database')
}
if (-not $ReportPath) {
    $ReportPath = [IO.Path]::Combine($repoRoot, 'artifacts', 'sql-policy-report.md')
}

# Source lint owns destructive DML and deployment-script idempotency.
# Generated destructive DDL is enforced by Test-DeploymentScript.ps1.
$rules = @(
    @{
        Id = 'SQL001'
        Severity = 'error'
        Pattern = '(?im)^\s*DELETE\s+(?:FROM\s+)?'
        Message = 'DELETE in project source or deployment scripts requires an explicit, reviewed migration.'
    },
    @{
        Id = 'SQL002'
        Severity = 'error'
        Pattern = '(?im)^\s*TRUNCATE\s+TABLE\b'
        Message = 'TRUNCATE TABLE is not allowed in project source or deployment scripts.'
    },
    @{
        Id = 'SQL004'
        Severity = 'warning'
        Pattern = '(?im)\bSELECT\s+\*'
        Message = 'Avoid SELECT * in persisted database objects.'
    },
    @{
        Id = 'SQL005'
        Severity = 'warning'
        Pattern = '(?im)\bNOLOCK\b'
        Message = 'NOLOCK can return inconsistent results and requires explicit review.'
    }
)

$findings = [System.Collections.Generic.List[object]]::new()
$files = @(Get-ChildItem -Path $SourcePath -Recurse -File -Filter '*.sql')

foreach ($file in $files) {
    $content = Get-Content -Path $file.FullName -Raw
    foreach ($rule in $rules) {
        foreach ($match in [regex]::Matches($content, $rule.Pattern)) {
            $line = ($content.Substring(0, $match.Index) -split "`n").Count
            $findings.Add([pscustomobject]@{
                Rule = $rule.Id
                Severity = $rule.Severity
                File = [IO.Path]::GetRelativePath($repoRoot, $file.FullName)
                Line = $line
                Message = $rule.Message
            })
        }
    }

    $isDeploymentScript = $file.FullName -match '[\\/]Scripts[\\/]'
    $hasInsert = $content -match '(?im)^\s*INSERT(?:\s+INTO)?\b'
    $hasIdempotentGuard = $content -match '(?is)\b(?:IF\s+NOT\s+EXISTS|WHERE\s+NOT\s+EXISTS|MERGE)\b'
    if ($isDeploymentScript -and $hasInsert -and -not $hasIdempotentGuard) {
        $insertMatch = [regex]::Match($content, '(?im)^\s*INSERT(?:\s+INTO)?\b')
        $findings.Add([pscustomobject]@{
            Rule = 'SQL003'
            Severity = 'error'
            File = [IO.Path]::GetRelativePath($repoRoot, $file.FullName)
            Line = ($content.Substring(0, $insertMatch.Index) -split "`n").Count
            Message = 'Deployment-script INSERT must be guarded by IF NOT EXISTS, WHERE NOT EXISTS, or MERGE.'
        })
    }
}

$reportDirectory = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null

$lines = @(
    '# SQL policy report',
    '',
    "Scanned $($files.Count) SQL files.",
    'This source lint checks destructive DML and deployment-script idempotency. Generated destructive DDL is enforced by eng/Test-DeploymentScript.ps1.',
    ''
)

if ($findings.Count -eq 0) {
    $lines += 'No policy findings.'
} else {
    $lines += '| Severity | Rule | File | Line | Message |'
    $lines += '|---|---|---|---:|---|'
    foreach ($finding in $findings) {
        $lines += "| $($finding.Severity) | $($finding.Rule) | $($finding.File) | $($finding.Line) | $($finding.Message) |"
    }
}

Set-Content -Path $ReportPath -Value $lines -Encoding utf8
Write-Host "SQL policy report: $ReportPath"

$errors = @($findings | Where-Object Severity -eq 'error')
if ($errors.Count -gt 0) {
    throw "SQL policy validation failed with $($errors.Count) error(s)."
}
