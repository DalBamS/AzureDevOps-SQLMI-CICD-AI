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
Import-Module (Join-Path $PSScriptRoot 'SqlCmd.Common.psm1') -Force

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $AllowlistPath) {
    $AllowlistPath = Join-Path $PSScriptRoot 'policy/deploy-allowlist.json'
}
if (-not $ReportPath) {
    $ReportPath = Join-Path $repoRoot 'artifacts/deployment-script-report.md'
}
if (-not (Test-Path $AllowlistPath -PathType Leaf)) {
    throw "Deployment allowlist not found: $AllowlistPath"
}

function Get-LineNumber {
    param([string]$Text, [int]$Index)
    return 1 + [regex]::Matches($Text.Substring(0, $Index), "`n").Count
}

function ConvertTo-MarkdownText {
    param([AllowEmptyString()][string]$Text)
    return (($Text -replace '\|', '\|' -replace '\r?\n', ' ') -replace '\s+', ' ').Trim()
}

function ConvertTo-ObjectName {
    param([string]$Name)
    return ($Name.Trim() -replace '^\[|\]$|^"|"$', '').ToLowerInvariant()
}

function Add-Finding {
    param(
        [Collections.Generic.List[object]]$Findings,
        [string]$Rule,
        [string]$Severity,
        [string]$Message,
        [string]$Statement,
        [int]$Line
    )
    $Findings.Add([pscustomobject]@{
        Rule = $Rule
        Severity = $Severity
        Line = $Line
        Message = $Message
        Statement = ($Statement -replace '\s+', ' ').Trim()
        AllowedBy = $null
    })
}

$resolution = Resolve-SqlCmdScript -Path $ScriptPath
$sql = $resolution.SanitizedText
$batches = @(Get-SqlBatch -Text $sql)
$findings = [Collections.Generic.List[object]]::new()
$identifier = '(?:\[[^\]]+\]|"[^"]+"|[A-Za-z_][A-Za-z0-9_$#@]*)'

$rules = @(
    @{
        Id = 'DEPLOY001'; Severity = 'error'
        Pattern = '(?is)\bDROP\s+TABLE\b(?:\s+IF\s+EXISTS\b)?[^\r\n;]*'
        Message = 'DROP TABLE requires an approved expand/contract migration.'
    },
    @{
        Id = 'DEPLOY002'; Severity = 'error'
        Pattern = '(?is)\bALTER\s+TABLE\b[^\r\n;]*?\bDROP\s+COLUMN\b[^\r\n;]*'
        Message = 'DROP COLUMN requires an approved expand/contract migration.'
    },
    @{
        Id = 'DEPLOY005'; Severity = 'error'
        Pattern = '(?is)\bTRUNCATE\s+TABLE\b[^\r\n;]*'
        Message = 'TRUNCATE TABLE removes all rows and is not allowed by default.'
    },
    @{
        Id = 'DEPLOY006'; Severity = 'warning'
        Pattern = '(?is)\bALTER\s+TABLE\b[^\r\n;]*?\bALTER\s+COLUMN\b[^\r\n;]*'
        Message = 'ALTER COLUMN can narrow data shape; review target data compatibility.'
    },
    @{
        Id = 'DEPLOY007'; Severity = 'warning'
        Pattern = '(?is)\bsp_rename\b[^\r\n;]*'
        Message = 'sp_rename can break dependencies; review the rename.'
    },
    @{
        Id = 'DEPLOY009'; Severity = 'warning'
        Pattern = '(?is)\bSET\s+NOEXEC\s+(?:ON|OFF)\b'
        Message = 'SET NOEXEC changes execution flow; confirm DacFx generated it.'
    },
    @{
        Id = 'DEPLOY008'; Severity = 'error'
        Pattern = '(?is)\bEXEC(?:UTE)?\s*\(\s*@|\bsp_executesql\s+@'
        Message = 'Variable-based dynamic SQL cannot be reviewed by this lightweight gate.'
    },
    @{
        Id = 'DEPLOY010'; Severity = 'error'
        Pattern = '(?im)\bEXEC(?:UTE)?\s+(?!\(?\s*N?''|@|(?:\[[^\]]+\]|"[^"]+"|[A-Za-z_])[A-Za-z0-9_$#@\.\[\]"]*\b)[^\r\n;]+'
        Message = 'EXEC procedure path is malformed or outside the supported text pattern.'
    }
)

foreach ($rule in $rules) {
    foreach ($match in [regex]::Matches($sql, $rule.Pattern)) {
        Add-Finding $findings $rule.Id $rule.Severity $rule.Message $match.Value (Get-LineNumber $sql $match.Index)
    }
}

$dropIndexPattern = "(?is)\bDROP\s+INDEX\s+(?<name>$identifier)(?=\s|;|$)[^\r\n;]*"
foreach ($match in [regex]::Matches($sql, $dropIndexPattern)) {
    $name = ConvertTo-ObjectName $match.Groups['name'].Value
    $createPattern = "(?is)\bCREATE\s+(?:UNIQUE\s+)?(?:CLUSTERED\s+|NONCLUSTERED\s+)?INDEX\s+(?<name>$identifier)(?=\s|;|$)"
    $recreated = @([regex]::Matches($sql, $createPattern) | Where-Object {
        (ConvertTo-ObjectName $_.Groups['name'].Value) -ceq $name
    }).Count -gt 0
    $severity = if ($recreated) { 'warning' } else { 'error' }
    $message = if ($recreated) {
        'DROP INDEX is paired with a CREATE of the same index name.'
    } else {
        'DROP INDEX has no CREATE of the same index name in this script.'
    }
    Add-Finding $findings 'DEPLOY003' $severity $message $match.Value (Get-LineNumber $sql $match.Index)
}

$dropConstraintPattern = "(?is)\bALTER\s+TABLE\b[^\r\n;]*?\bDROP\s+CONSTRAINT\s+(?<name>$identifier)"
foreach ($match in [regex]::Matches($sql, $dropConstraintPattern)) {
    $name = ConvertTo-ObjectName $match.Groups['name'].Value
    $createPattern = "(?is)\bADD\s+(?:CONSTRAINT\s+)?(?<name>$identifier)\s+(?:PRIMARY|FOREIGN|UNIQUE|CHECK|DEFAULT)\b"
    $recreated = @([regex]::Matches($sql, $createPattern) | Where-Object {
        (ConvertTo-ObjectName $_.Groups['name'].Value) -ceq $name
    }).Count -gt 0
    $severity = if ($recreated) { 'warning' } else { 'error' }
    $message = if ($recreated) {
        'DROP CONSTRAINT is paired with an ADD of the same constraint name.'
    } else {
        'DROP CONSTRAINT has no ADD of the same constraint name in this script.'
    }
    Add-Finding $findings 'DEPLOY004' $severity $message $match.Value (Get-LineNumber $sql $match.Index)
}

$knownRuleIds = @($rules.Id) + @('DEPLOY003', 'DEPLOY004')
$activeAllowlist = [Collections.Generic.List[object]]::new()
$expiredAllowlist = [Collections.Generic.List[object]]::new()
$today = (Get-Date).ToUniversalTime().Date
foreach ($entry in @(Get-Content $AllowlistPath -Raw | ConvertFrom-Json)) {
    foreach ($property in @('rule', 'pattern', 'ticket', 'expiresOn')) {
        if (-not $entry.PSObject.Properties[$property] -or [string]::IsNullOrWhiteSpace($entry.$property)) {
            throw "Allowlist entry is missing required property '$property'."
        }
    }
    if ($knownRuleIds -notcontains $entry.rule) {
        throw "Allowlist entry has unknown rule '$($entry.rule)'."
    }
    try {
        [void][regex]::new($entry.pattern)
        $expiresOn = [datetime]::ParseExact(
            $entry.expiresOn, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture
        ).Date
    }
    catch {
        throw "Allowlist entry for '$($entry.rule)' is invalid: $($_.Exception.Message)"
    }
    $normalized = [pscustomobject]@{
        Rule = $entry.rule
        Pattern = $entry.pattern
        Ticket = $entry.ticket
        ExpiresOn = $expiresOn
    }
    if ($expiresOn -lt $today) {
        $expiredAllowlist.Add($normalized)
    } else {
        $activeAllowlist.Add($normalized)
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

$unallowed = @($findings | Where-Object { -not $_.AllowedBy })
$errorCount = @($unallowed | Where-Object Severity -eq 'error').Count
$warningCount = @($unallowed | Where-Object Severity -eq 'warning').Count
$reportLines = @(
    '# Deployment script policy report', '',
    "- Script: ``$([IO.Path]::GetFullPath($ScriptPath))``",
    "- GO-delimited batches: $($batches.Count)",
    "- Sanitized SQL SHA-256: $($resolution.SanitizedSha256)",
    "- Errors: $errorCount",
    "- Warnings: $warningCount", ''
)
if ($findings.Count -eq 0) {
    $reportLines += 'No deployment script findings.'
} else {
    $reportLines += '| Status | Severity | Rule | Line | Statement | Message |'
    $reportLines += '|---|---|---|---:|---|---|'
    foreach ($finding in $findings) {
        $status = if ($finding.AllowedBy) { "allowlisted: $($finding.AllowedBy)" } else { 'active' }
        $reportLines += "| $(ConvertTo-MarkdownText $status) | $($finding.Severity) | $($finding.Rule) | $($finding.Line) | ``$(ConvertTo-MarkdownText $finding.Statement)`` | $(ConvertTo-MarkdownText $finding.Message) |"
    }
}
if ($expiredAllowlist.Count -gt 0) {
    $reportLines += @('', '## Expired allowlist entries', '')
    foreach ($entry in $expiredAllowlist) {
        $reportLines += "- $($entry.Rule): $($entry.Ticket) expired $($entry.ExpiresOn.ToString('yyyy-MM-dd'))"
    }
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReportPath) | Out-Null
Set-Content -Path $ReportPath -Value $reportLines -Encoding utf8
Write-Host "Deployment script policy report: $ReportPath"
if ($errorCount -gt 0) {
    throw "Deployment script policy failed with $errorCount error(s)."
}
