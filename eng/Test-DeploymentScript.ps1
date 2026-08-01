[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ScriptPath,
    [string]$AllowlistPath,
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $AllowlistPath) {
    $AllowlistPath = [IO.Path]::Combine($PSScriptRoot, 'policy', 'deploy-allowlist.json')
}
if (-not $ReportPath) {
    $ReportPath = [IO.Path]::Combine($repoRoot, 'artifacts', 'deployment-script-report.md')
}
if (-not (Test-Path $AllowlistPath -PathType Leaf)) {
    throw "Deployment allowlist not found: $AllowlistPath"
}

function ConvertTo-CodeOnly {
    param([Parameter(Mandatory)][string]$Text)

    $pattern = "(?s)/\*.*?\*/|--[^\r\n]*|N?'(?:''|[^'])*'"
    return [regex]::Replace(
        $Text,
        $pattern,
        [System.Text.RegularExpressions.MatchEvaluator] {
            param($match)
            return [regex]::Replace($match.Value, '[^\r\n]', ' ')
        }
    )
}

function Get-LineNumber {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$StartLine
    )

    return $StartLine + [regex]::Matches($Text.Substring(0, $Index), "`n").Count
}

function ConvertTo-MarkdownText {
    param([AllowEmptyString()][string]$Text)

    return (($Text -replace '\|', '\|' -replace '\r?\n', ' ') -replace '\s+', ' ').Trim()
}

$rules = @(
    @{
        Id = 'DEPLOY001'
        Severity = 'error'
        Pattern = '(?is)\bDROP\s+TABLE\b(?:\s+IF\s+EXISTS\b)?[^\r\n;]*'
        Message = 'DROP TABLE requires an approved expand/contract migration.'
    },
    @{
        Id = 'DEPLOY002'
        Severity = 'error'
        Pattern = '(?is)\bALTER\s+TABLE\b(?:(?!\bALTER\s+TABLE\b)[\s\S]){0,1000}?\bDROP\s+COLUMN\b[^\r\n;]*'
        Message = 'DROP COLUMN requires an approved expand/contract migration.'
    },
    @{
        Id = 'DEPLOY003'
        Severity = 'error'
        Pattern = '(?is)\bDROP\s+INDEX\b[^\r\n;]*'
        Message = 'DROP INDEX requires explicit deployment review.'
    },
    @{
        Id = 'DEPLOY004'
        Severity = 'error'
        Pattern = '(?is)\bALTER\s+TABLE\b(?:(?!\bALTER\s+TABLE\b)[\s\S]){0,1000}?\bDROP\s+CONSTRAINT\b[^\r\n;]*'
        Message = 'DROP CONSTRAINT requires explicit deployment review.'
    },
    @{
        Id = 'DEPLOY005'
        Severity = 'error'
        Pattern = '(?is)\bTRUNCATE\s+TABLE\b[^\r\n;]*'
        Message = 'TRUNCATE TABLE removes all rows and is not allowed by default.'
    },
    @{
        Id = 'DEPLOY006'
        Severity = 'warning'
        Pattern = '(?is)\bALTER\s+TABLE\b(?:(?!\bALTER\s+TABLE\b)[\s\S]){0,1000}?\bALTER\s+COLUMN\b[^\r\n;]*'
        Message = 'ALTER COLUMN can narrow a type, length, precision, or nullability; review target data compatibility.'
    },
    @{
        Id = 'DEPLOY007'
        Severity = 'error'
        Pattern = '(?is)\bEXEC(?:UTE)?\s+(?:\[?sys\]?\.)?\[?sp_rename\]?\b[^\r\n;]*'
        Message = 'sp_rename can break dependencies and requires explicit approval.'
    },
    @{
        Id = 'DEPLOY009'
        Severity = 'warning'
        Pattern = '(?is)\bSET\s+NOEXEC\s+(?:ON|OFF)\b'
        Message = 'SET NOEXEC changes execution flow; confirm it is DacFx-generated guard logic.'
    }
)

$knownRuleIds = @($rules.Id) + 'DEPLOY008'
$allowlist = @(Get-Content -Path $AllowlistPath -Raw | ConvertFrom-Json)
$activeAllowlist = [System.Collections.Generic.List[object]]::new()
$expiredAllowlist = [System.Collections.Generic.List[object]]::new()
$today = (Get-Date).ToUniversalTime().Date

foreach ($entry in $allowlist) {
    foreach ($property in @('rule', 'pattern', 'ticket', 'expiresOn')) {
        if (-not $entry.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace([string]$entry.$property)) {
            throw "Allowlist entry is missing required property '$property': $AllowlistPath"
        }
    }
    if ($knownRuleIds -notcontains [string]$entry.rule) {
        throw "Allowlist entry has unknown rule '$($entry.rule)': $AllowlistPath"
    }
    try {
        [void][regex]::new([string]$entry.pattern)
        $expiresOn = [datetime]::ParseExact(
            [string]$entry.expiresOn,
            'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture
        ).Date
    }
    catch {
        throw "Allowlist entry for '$($entry.rule)' has an invalid pattern or expiresOn date: $($_.Exception.Message)"
    }

    $normalized = [pscustomobject]@{
        Rule = [string]$entry.rule
        Pattern = [string]$entry.pattern
        Ticket = [string]$entry.ticket
        ExpiresOn = $expiresOn
    }
    if ($expiresOn -lt $today) {
        $expiredAllowlist.Add($normalized)
    }
    else {
        $activeAllowlist.Add($normalized)
    }
}

$scriptLines = @(Get-Content -Path $ScriptPath)
$batches = [System.Collections.Generic.List[object]]::new()
$batchLines = [System.Collections.Generic.List[string]]::new()
$batchStartLine = 1

for ($index = 0; $index -lt $scriptLines.Count; $index++) {
    $line = $scriptLines[$index]
    if ($line -match '^\s*GO(?:\s+\d+)?\s*(?:--.*)?$') {
        if ($batchLines.Count -gt 0) {
            $batches.Add([pscustomobject]@{
                Text = $batchLines -join "`n"
                StartLine = $batchStartLine
            })
            $batchLines.Clear()
        }
        $batchStartLine = $index + 2
        continue
    }
    $batchLines.Add($line)
}
if ($batchLines.Count -gt 0) {
    $batches.Add([pscustomobject]@{
        Text = $batchLines -join "`n"
        StartLine = $batchStartLine
    })
}

$findings = [System.Collections.Generic.List[object]]::new()
foreach ($batch in $batches) {
    $codeOnly = ConvertTo-CodeOnly -Text $batch.Text
    foreach ($rule in $rules) {
        foreach ($match in [regex]::Matches($codeOnly, $rule.Pattern)) {
            $statement = ($batch.Text.Substring($match.Index, $match.Length) -replace '\s+', ' ').Trim()
            $findings.Add([pscustomobject]@{
                Rule = $rule.Id
                Severity = $rule.Severity
                Line = Get-LineNumber -Text $batch.Text -Index $match.Index -StartLine $batch.StartLine
                Message = $rule.Message
                Statement = $statement
                AllowedBy = $null
            })
        }
    }

    $executeMatches = [regex]::Matches(
        $codeOnly,
        '(?is)\bEXEC(?:UTE)?\s+(?:\[?sys\]?\.)?\[?sp_executesql\]?\b'
    )
    foreach ($executeMatch in $executeMatches) {
        $dynamicStrings = [regex]::Matches($batch.Text, "(?is)N?'((?:''|[^'])*)'")
        foreach ($dynamicString in $dynamicStrings) {
            $dynamicSql = $dynamicString.Groups[1].Value -replace "''", "'"
            if ($dynamicSql -notmatch '(?is)\b(?:(?:CREATE|ALTER|DROP)\s+(?:TABLE|VIEW|PROCEDURE|PROC|FUNCTION|INDEX|SCHEMA|TRIGGER|TYPE|SEQUENCE|SYNONYM|DATABASE|ROLE|USER|LOGIN)|TRUNCATE\s+TABLE|EXEC(?:UTE)?\s+(?:sys\.)?sp_rename)\b') {
                continue
            }
            $findings.Add([pscustomobject]@{
                Rule = 'DEPLOY008'
                Severity = 'error'
                Line = Get-LineNumber -Text $batch.Text -Index $executeMatch.Index -StartLine $batch.StartLine
                Message = 'Dynamic DDL executed through sp_executesql cannot be reviewed reliably.'
                Statement = ($dynamicSql -replace '\s+', ' ').Trim()
                AllowedBy = $null
            })
        }
    }
}

foreach ($finding in $findings) {
    foreach ($entry in $activeAllowlist) {
        if ($entry.Rule -eq $finding.Rule -and $finding.Statement -match $entry.Pattern) {
            $finding.AllowedBy = "$($entry.Ticket) (expires $($entry.ExpiresOn.ToString('yyyy-MM-dd')))"
            break
        }
    }
}

$reportDirectory = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
$unallowed = @($findings | Where-Object { -not $_.AllowedBy })
$errorCount = @($unallowed | Where-Object Severity -eq 'error').Count
$warningCount = @($unallowed | Where-Object Severity -eq 'warning').Count
$allowedCount = @($findings | Where-Object AllowedBy).Count

$reportLines = @(
    '# Deployment script policy report',
    '',
    "- Script: ``$(ConvertTo-MarkdownText ([IO.Path]::GetFullPath($ScriptPath)))``",
    "- GO-delimited batches: $($batches.Count)",
    "- Errors: $errorCount",
    "- Warnings: $warningCount",
    "- Allowlisted findings: $allowedCount",
    ''
)

if ($findings.Count -eq 0) {
    $reportLines += 'No deployment script findings.'
}
else {
    $reportLines += '| Status | Severity | Rule | Line | Statement | Message |'
    $reportLines += '|---|---|---|---:|---|---|'
    foreach ($finding in $findings) {
        $status = if ($finding.AllowedBy) { "allowlisted: $($finding.AllowedBy)" } else { 'active' }
        $reportLines += "| $(ConvertTo-MarkdownText $status) | $($finding.Severity) | $($finding.Rule) | $($finding.Line) | ``$(ConvertTo-MarkdownText $finding.Statement)`` | $(ConvertTo-MarkdownText $finding.Message) |"
    }
}

if ($expiredAllowlist.Count -gt 0) {
    $reportLines += @('', '## Expired allowlist entries', '')
    $reportLines += '| Rule | Pattern | Ticket | Expires on |'
    $reportLines += '|---|---|---|---|'
    foreach ($entry in $expiredAllowlist) {
        $reportLines += "| $($entry.Rule) | ``$(ConvertTo-MarkdownText $entry.Pattern)`` | $(ConvertTo-MarkdownText $entry.Ticket) | $($entry.ExpiresOn.ToString('yyyy-MM-dd')) |"
    }
}

Set-Content -Path $ReportPath -Value $reportLines -Encoding utf8
Write-Host "Deployment script policy report: $ReportPath"

if ($errorCount -gt 0) {
    throw "Deployment script policy failed with $errorCount error(s)."
}
