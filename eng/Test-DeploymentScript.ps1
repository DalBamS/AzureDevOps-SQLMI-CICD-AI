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

function ConvertTo-SqlLexicalView {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [switch]$MaskString
    )

    $result = [Text.StringBuilder]::new($Text.Length)
    for ($index = 0; $index -lt $Text.Length; $index++) {
        if (
            $Text[$index] -eq '-' -and
            $index + 1 -lt $Text.Length -and
            $Text[$index + 1] -eq '-'
        ) {
            while ($index -lt $Text.Length -and $Text[$index] -notin "`r", "`n") {
                [void]$result.Append(' ')
                $index++
            }
            if ($index -lt $Text.Length) {
                [void]$result.Append($Text[$index])
            }
            continue
        }
        if (
            $Text[$index] -eq '/' -and
            $index + 1 -lt $Text.Length -and
            $Text[$index + 1] -eq '*'
        ) {
            $depth = 1
            [void]$result.Append('  ')
            $index += 2
            while ($index -lt $Text.Length -and $depth -gt 0) {
                if (
                    $Text[$index] -eq '/' -and
                    $index + 1 -lt $Text.Length -and
                    $Text[$index + 1] -eq '*'
                ) {
                    $depth++
                    [void]$result.Append('  ')
                    $index += 2
                    continue
                }
                if (
                    $Text[$index] -eq '*' -and
                    $index + 1 -lt $Text.Length -and
                    $Text[$index + 1] -eq '/'
                ) {
                    $depth--
                    [void]$result.Append('  ')
                    $index += 2
                    continue
                }
                [void]$result.Append($(if ($Text[$index] -in "`r", "`n") { $Text[$index] } else { ' ' }))
                $index++
            }
            if ($depth -ne 0) {
                throw 'Deployment script contains an unterminated block comment.'
            }
            $index--
            continue
        }
        if ($Text[$index] -eq '[') {
            [void]$result.Append('[')
            $index++
            $closed = $false
            while ($index -lt $Text.Length) {
                [void]$result.Append($Text[$index])
                if ($Text[$index] -ne ']') {
                    $index++
                    continue
                }
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq ']') {
                    [void]$result.Append(']')
                    $index += 2
                    continue
                }
                $closed = $true
                break
            }
            if (-not $closed) {
                throw 'Deployment script contains an unterminated bracket-quoted identifier.'
            }
            continue
        }
        if ($Text[$index] -eq "'") {
            [void]$result.Append($(if ($MaskString) { ' ' } else { "'" }))
            $index++
            $closed = $false
            while ($index -lt $Text.Length) {
                if ($Text[$index] -ne "'") {
                    [void]$result.Append($(if ($MaskString -and $Text[$index] -notin "`r", "`n") { ' ' } else { $Text[$index] }))
                    $index++
                    continue
                }
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq "'") {
                    [void]$result.Append($(if ($MaskString) { '  ' } else { "''" }))
                    $index += 2
                    continue
                }
                [void]$result.Append($(if ($MaskString) { ' ' } else { "'" }))
                $closed = $true
                break
            }
            if (-not $closed) {
                throw 'Deployment script contains an unterminated string literal.'
            }
            continue
        }
        [void]$result.Append($Text[$index])
    }
    return $result.ToString()
}

function ConvertTo-CodeOnly {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return ConvertTo-SqlLexicalView -Text $Text -MaskString
}

function ConvertTo-CommentFreeSql {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return ConvertTo-SqlLexicalView -Text $Text
}

function Get-SqlStatement {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $inString = $false
    for ($index = $StartIndex; $index -lt $Text.Length; $index++) {
        if ($Text[$index] -eq "'") {
            if ($inString -and $index + 1 -lt $Text.Length -and $Text[$index + 1] -eq "'") {
                $index++
                continue
            }
            $inString = -not $inString
            continue
        }
        if (-not $inString -and $Text[$index] -eq ';') {
            return $Text.Substring($StartIndex, $index - $StartIndex + 1)
        }
    }
    return $Text.Substring($StartIndex)
}

function ConvertFrom-ConstantSqlExpression {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $cursor = $StartIndex
    $value = [Text.StringBuilder]::new()
    $literalCount = 0
    while ($true) {
        while ($cursor -lt $Text.Length -and [char]::IsWhiteSpace($Text[$cursor])) {
            $cursor++
        }
        if (
            $cursor + 1 -lt $Text.Length -and
            ($Text[$cursor] -eq 'N' -or $Text[$cursor] -eq 'n') -and
            $Text[$cursor + 1] -eq "'"
        ) {
            $cursor++
        }
        if ($cursor -ge $Text.Length -or $Text[$cursor] -ne "'") {
            return [pscustomobject]@{ Success = $false; Value = ''; EndIndex = $cursor }
        }
        $cursor++
        $closed = $false
        while ($cursor -lt $Text.Length) {
            if ($Text[$cursor] -ne "'") {
                [void]$value.Append($Text[$cursor])
                $cursor++
                continue
            }
            if ($cursor + 1 -lt $Text.Length -and $Text[$cursor + 1] -eq "'") {
                [void]$value.Append("'")
                $cursor += 2
                continue
            }
            $cursor++
            $closed = $true
            break
        }
        if (-not $closed) {
            return [pscustomobject]@{ Success = $false; Value = ''; EndIndex = $cursor }
        }
        $literalCount++
        while ($cursor -lt $Text.Length -and [char]::IsWhiteSpace($Text[$cursor])) {
            $cursor++
        }
        if ($cursor -ge $Text.Length -or $Text[$cursor] -ne '+') {
            break
        }
        $cursor++
    }
    return [pscustomobject]@{
        Success = $literalCount -gt 0
        Value = $value.ToString()
        EndIndex = $cursor
    }
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

function Add-DynamicExecutionFinding {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$StartLine,
        [Parameter(Mandatory)][int]$Depth,
        [Parameter(Mandatory)][object[]]$Rules,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Findings
    )

    if ($Depth -gt 8) {
        $Findings.Add([pscustomobject]@{
            Rule = 'DEPLOY008'
            Severity = 'error'
            Line = $StartLine
            Message = 'Dynamic SQL nesting exceeds the deterministic review limit.'
            Statement = ($Text -replace '\s+', ' ').Trim()
            AllowedBy = $null
        })
        return
    }

    $codeOnly = ConvertTo-CodeOnly -Text $Text
    $commentFree = ConvertTo-CommentFreeSql -Text $Text
    foreach ($executeMatch in [regex]::Matches($codeOnly, '(?is)\bEXEC(?:UTE)?\b')) {
        $statement = Get-SqlStatement -Text $commentFree -StartIndex $executeMatch.Index
        $findingLine = if ($Depth -eq 0) {
            Get-LineNumber -Text $Text -Index $executeMatch.Index -StartLine $StartLine
        }
        else {
            $StartLine
        }
        $cursor = $executeMatch.Length
        while ($cursor -lt $statement.Length -and [char]::IsWhiteSpace($statement[$cursor])) {
            $cursor++
        }
        $returnAssignment = [regex]::Match(
            $statement.Substring($cursor),
            '^(?is)@[A-Za-z_][A-Za-z0-9_]*\s*=\s*'
        )
        if ($returnAssignment.Success) {
            $cursor += $returnAssignment.Length
        }
        $parenthesized = $cursor -lt $statement.Length -and $statement[$cursor] -eq '('
        if ($parenthesized) {
            $cursor++
            while ($cursor -lt $statement.Length -and [char]::IsWhiteSpace($statement[$cursor])) {
                $cursor++
            }
        }
        $spExecuteSql = [regex]::Match(
            $statement.Substring($cursor),
            '^(?is)(?:(?:\[[^\]]+\]|[A-Za-z_][A-Za-z0-9_@$#]*)\s*\.\s*){0,3}\[?sp_executesql\]?\b'
        )
        if ($spExecuteSql.Success) {
            $cursor += $spExecuteSql.Length
            while ($cursor -lt $statement.Length -and [char]::IsWhiteSpace($statement[$cursor])) {
                $cursor++
            }
            $namedStatement = [regex]::Match(
                $statement.Substring($cursor),
                '^(?is)@stmt\s*=\s*'
            )
            if ($namedStatement.Success) {
                $cursor += $namedStatement.Length
            }
        }
        $startsWithLiteral = (
            $cursor -lt $statement.Length -and $statement[$cursor] -eq "'"
        ) -or (
            $cursor + 1 -lt $statement.Length -and
            ($statement[$cursor] -eq 'N' -or $statement[$cursor] -eq 'n') -and
            $statement[$cursor + 1] -eq "'"
        )
        $startsWithVariable = $cursor -lt $statement.Length -and $statement[$cursor] -eq '@'
        if (
            -not $parenthesized -and
            -not $spExecuteSql.Success -and
            -not $startsWithLiteral -and
            -not $startsWithVariable
        ) {
            continue
        }

        $expression = ConvertFrom-ConstantSqlExpression -Text $statement -StartIndex $cursor
        if (-not $expression.Success) {
            $Findings.Add([pscustomobject]@{
                Rule = 'DEPLOY008'
                Severity = 'error'
                Line = $findingLine
                Message = 'Dynamic SQL execution is not a constant string expression and is blocked.'
                Statement = ($statement -replace '\s+', ' ').Trim()
                AllowedBy = $null
            })
            continue
        }
        $afterExpression = $expression.EndIndex
        while ($afterExpression -lt $statement.Length -and [char]::IsWhiteSpace($statement[$afterExpression])) {
            $afterExpression++
        }
        if (
            $parenthesized -and
            ($afterExpression -ge $statement.Length -or $statement[$afterExpression] -ne ')')
        ) {
            $Findings.Add([pscustomobject]@{
                Rule = 'DEPLOY008'
                Severity = 'error'
                Line = $findingLine
                Message = 'Dynamic SQL execution contains an unsupported expression and is blocked.'
                Statement = ($statement -replace '\s+', ' ').Trim()
                AllowedBy = $null
            })
            continue
        }

        $dynamicSql = $expression.Value
        $dynamicCodeOnly = ConvertTo-CodeOnly -Text $dynamicSql
        foreach ($rule in $Rules) {
            foreach ($match in [regex]::Matches($dynamicCodeOnly, $rule.Pattern)) {
                $dynamicStatement = (
                    $dynamicSql.Substring($match.Index, $match.Length) -replace '\s+', ' '
                ).Trim()
                $Findings.Add([pscustomobject]@{
                    Rule = $rule.Id
                    Severity = $rule.Severity
                    Line = $findingLine
                    Message = "Dynamic SQL: $($rule.Message)"
                    Statement = $dynamicStatement
                    AllowedBy = $null
                })
            }
        }
        if ($dynamicCodeOnly -match '(?is)\b(?:(?:CREATE|ALTER|DROP)\s+(?:TABLE|VIEW|PROCEDURE|PROC|FUNCTION|INDEX|SCHEMA|TRIGGER|TYPE|SEQUENCE|SYNONYM|DATABASE|ROLE|USER|LOGIN)|TRUNCATE\s+TABLE|EXEC(?:UTE)?\s+(?:sys\.)?sp_rename)\b') {
            $Findings.Add([pscustomobject]@{
                Rule = 'DEPLOY008'
                Severity = 'error'
                Line = $findingLine
                Message = 'Constant dynamic DDL requires explicit deployment review.'
                Statement = ($dynamicSql -replace '\s+', ' ').Trim()
                AllowedBy = $null
            })
        }
        Add-DynamicExecutionFinding `
            -Text $dynamicSql `
            -StartLine $findingLine `
            -Depth ($Depth + 1) `
            -Rules $Rules `
            -Findings $Findings
    }
}

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

    Add-DynamicExecutionFinding `
        -Text $batch.Text `
        -StartLine $batch.StartLine `
        -Depth 0 `
        -Rules $rules `
        -Findings $findings
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
