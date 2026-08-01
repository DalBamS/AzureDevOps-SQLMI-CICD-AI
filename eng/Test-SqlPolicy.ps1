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

$rules = @(
    @{
        Id = 'DB001'
        Severity = 'error'
        Pattern = '(?im)^\s*DROP\s+(TABLE|COLUMN|DATABASE)\b'
        Message = 'Destructive DROP statements require an approved expand/contract migration.'
    },
    @{
        Id = 'DB002'
        Severity = 'error'
        Pattern = '(?im)^\s*TRUNCATE\s+TABLE\b'
        Message = 'TRUNCATE TABLE is not allowed in the state-based database project.'
    },
    @{
        Id = 'DB003'
        Severity = 'warning'
        Pattern = '(?im)\bSELECT\s+\*'
        Message = 'Avoid SELECT * in persisted database objects.'
    },
    @{
        Id = 'DB004'
        Severity = 'warning'
        Pattern = '(?im)\bNOLOCK\b'
        Message = 'NOLOCK can return inconsistent results and requires explicit review.'
    }
)

$findings = [System.Collections.Generic.List[object]]::new()
$files = Get-ChildItem -Path $SourcePath -Recurse -File -Filter '*.sql' |
    Where-Object { $_.FullName -notmatch '[\\/]Scripts[\\/]Seed[\\/]' }

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
}

$reportDirectory = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null

$lines = @(
    '# SQL policy report',
    '',
    "Scanned $($files.Count) SQL files.",
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
