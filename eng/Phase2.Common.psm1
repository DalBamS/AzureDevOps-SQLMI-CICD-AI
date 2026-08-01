Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-UnresolvedPipelineValue {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    return [string]::IsNullOrWhiteSpace($Value) -or $Value -match '^\$\([^)]+\)$'
}

function Resolve-DatabaseNames {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DatabaseNames,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DatabaseName
    )

    $source = if (-not (Test-UnresolvedPipelineValue $DatabaseNames)) {
        $DatabaseNames
    }
    elseif (-not (Test-UnresolvedPipelineValue $DatabaseName)) {
        $DatabaseName
    }
    else {
        throw 'Set databaseNames to a comma-separated list or set the backward-compatible databaseName value.'
    }

    $resolved = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($candidate in $source.Split(',')) {
        $name = $candidate.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'databaseNames contains an empty database name.'
        }
        if ($name -notmatch '^[A-Za-z0-9_-]+$') {
            throw "Database name '$name' must contain only letters, numbers, underscores, or hyphens."
        }
        if ($seen.Add($name)) {
            $resolved.Add($name)
        }
    }

    if ($resolved.Count -eq 0) {
        throw 'No target databases were resolved.'
    }

    return $resolved.ToArray()
}

function Get-DatabaseRollout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$DatabaseNames
    )

    return [pscustomobject]@{
        Canary = $DatabaseNames[0]
        Remaining = @($DatabaseNames | Select-Object -Skip 1)
    }
}

function Test-DeployReportHasChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path
    )

    [xml]$report = Get-Content -Path $Path -Raw
    return $report.SelectNodes("//*[local-name()='Operation']").Count -gt 0
}

function ConvertFrom-NestedSqlBlockComment {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $result = [Text.StringBuilder]::new($Text.Length)
    $index = 0
    while ($index -lt $Text.Length) {
        if ($Text[$index] -eq "'") {
            [void]$result.Append("'")
            $index++
            $closed = $false
            while ($index -lt $Text.Length) {
                [void]$result.Append($Text[$index])
                if ($Text[$index] -ne "'") {
                    $index++
                    continue
                }
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq "'") {
                    [void]$result.Append("'")
                    $index += 2
                    continue
                }
                $index++
                $closed = $true
                break
            }
            if (-not $closed) {
                throw 'DacFx script contains an unterminated string literal.'
            }
            continue
        }
        if ($Text[$index] -in '[', '"') {
            $opening = $Text[$index]
            $closing = if ($opening -eq '[') { ']' } else { '"' }
            [void]$result.Append($opening)
            $index++
            $closed = $false
            while ($index -lt $Text.Length) {
                [void]$result.Append($Text[$index])
                if ($Text[$index] -ne $closing) {
                    $index++
                    continue
                }
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq $closing) {
                    [void]$result.Append($closing)
                    $index += 2
                    continue
                }
                $index++
                $closed = $true
                break
            }
            if (-not $closed) {
                throw 'DacFx script contains an unterminated quoted identifier.'
            }
            continue
        }
        if (
            $Text[$index] -eq '/' -and
            $index + 1 -lt $Text.Length -and
            $Text[$index + 1] -eq '*'
        ) {
            $depth = 1
            $index += 2
            while ($index -lt $Text.Length -and $depth -gt 0) {
                if (
                    $Text[$index] -eq '/' -and
                    $index + 1 -lt $Text.Length -and
                    $Text[$index + 1] -eq '*'
                ) {
                    $depth++
                    $index += 2
                    continue
                }
                if (
                    $Text[$index] -eq '*' -and
                    $index + 1 -lt $Text.Length -and
                    $Text[$index + 1] -eq '/'
                ) {
                    $depth--
                    $index += 2
                    continue
                }
                if ($Text[$index] -in "`r", "`n") {
                    [void]$result.Append($Text[$index])
                }
                $index++
            }
            if ($depth -ne 0) {
                throw 'DacFx script contains an unterminated block comment.'
            }
            continue
        }
        [void]$result.Append($Text[$index])
        $index++
    }
    return $result.ToString()
}

function Get-DacFxPostDeploymentPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,
        [switch]$RequirePostDeploymentOnly
    )

    $startMarker = '-- SQLMI-CICD POSTDEPLOY START v1'
    $endMarker = '-- SQLMI-CICD POSTDEPLOY END v1'
    $text = (Get-Content -Path $Path -Raw) -replace "`r`n", "`n"
    $startMatches = @([regex]::Matches($text, "(?m)^$([regex]::Escape($startMarker))$"))
    $endMatches = @([regex]::Matches($text, "(?m)^$([regex]::Escape($endMarker))$"))
    if ($startMatches.Count -ne 1 -or $endMatches.Count -ne 1) {
        throw 'DacFx script must contain exactly one approved post-deployment marker pair.'
    }
    $start = $startMatches[0]
    $end = $endMatches[0]
    if ($end.Index -le $start.Index) {
        throw 'DacFx post-deployment markers are out of order.'
    }
    $payloadStart = $start.Index + $start.Length
    $payload = $text.Substring($payloadStart, $end.Index - $payloadStart)
    if ([string]::IsNullOrWhiteSpace($payload)) {
        throw 'DacFx post-deployment payload is empty.'
    }

    if ($RequirePostDeploymentOnly) {
        $prefix = ConvertFrom-NestedSqlBlockComment -Text $text.Substring(0, $start.Index)
        $suffix = $text.Substring($end.Index + $end.Length)
        $prefixPattern = @'
(?isx)\A\s*
GO\s+
SET\s+ANSI_NULLS\s*,\s*ANSI_PADDING\s*,\s*ANSI_WARNINGS\s*,\s*ARITHABORT\s*,\s*CONCAT_NULL_YIELDS_NULL\s*,\s*QUOTED_IDENTIFIER\s+ON\s*;\s*
SET\s+NUMERIC_ROUNDABORT\s+OFF\s*;\s*
GO\s*
:setvar\s+DatabaseName\s+"[^"\r\n]+"\s*
:setvar\s+DefaultFilePrefix\s+"[^"\r\n]+"\s*
:setvar\s+DefaultDataPath\s+"[^"\r\n]+"\s*
:setvar\s+DefaultLogPath\s+"[^"\r\n]+"\s*
GO\s*
:on\s+error\s+exit\s*
GO\s*
:setvar\s+__IsSqlCmdEnabled\s+"True"\s*
GO\s*
IF\s+N'\$\(__IsSqlCmdEnabled\)'\s+NOT\s+LIKE\s+N'True'\s*
BEGIN\s*
PRINT\s+N'(?:''|[^'])*'\s*;\s*
SET\s+NOEXEC\s+ON\s*;\s*
END\s*
GO\s*
USE\s+\[\$\(DatabaseName\)\]\s*;\s*
GO\s*\z
'@
        $suffixPattern = @'
(?isx)\A\s*
GO\s*
GO\s*
PRINT\s+N'(?:''|[^'])*'\s*;\s*
GO\s*\z
'@
        if ($prefix -notmatch $prefixPattern -or $suffix -notmatch $suffixPattern) {
            throw 'Current DacFx script contains schema or pre-deployment SQL outside the approved post-deployment payload.'
        }
    }

    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    return [pscustomobject]@{
        Contract = 'sqlmi-cicd-postdeploy-v1'
        Payload = $payload
        Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    }
}

function Invoke-DatabaseFanOut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$DatabaseNames,
        [Parameter(Mandatory)]
        [scriptblock]$Operation,
        [Parameter(Mandatory)]
        [psobject]$Context,
        [ValidateRange(1, 64)]
        [int]$MaxParallel = 4
    )

    if ($DatabaseNames.Count -eq 0) {
        return @()
    }
    if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
        throw 'Start-ThreadJob is required for throttled database fan-out. Use PowerShell 7 or later.'
    }

    $jobs = [System.Collections.Generic.List[object]]::new()
    $databaseByJobId = @{}
    try {
        foreach ($database in $DatabaseNames) {
            $job = Start-ThreadJob `
                -ThrottleLimit $MaxParallel `
                -ScriptBlock $Operation `
                -ArgumentList $database, $Context
            $jobs.Add($job)
            $databaseByJobId[$job.Id] = $database
        }

        [void](Wait-Job -Job $jobs.ToArray())
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($job in $jobs) {
            $database = $databaseByJobId[$job.Id]
            try {
                $output = @(Receive-Job -Job $job -ErrorAction Stop)
                $result = @(
                    $output |
                        Where-Object { $_.PSObject.Properties['DatabaseName'] }
                ) | Select-Object -Last 1
                if (-not $result) {
                    throw "Database worker for '$database' did not return a result."
                }
                $results.Add($result)
            }
            catch {
                $results.Add([pscustomobject]@{
                    DatabaseName = $database
                    Success = $false
                    Status = 'Failed'
                    Error = $_.Exception.Message
                })
            }
        }
        return $results.ToArray()
    }
    finally {
        if ($jobs.Count -gt 0) {
            Remove-Job -Job $jobs.ToArray() -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-DatabaseDeploymentSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Results,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SummaryPath,
        [Parameter(Mandatory)]
        [string]$EnvironmentName
    )

    $succeeded = @($Results | Where-Object Success)
    $failed = @($Results | Where-Object { -not $_.Success })
    $lines = @(
        "## Database deployment summary: $EnvironmentName",
        '',
        "- Total: $($Results.Count)",
        "- Succeeded: $($succeeded.Count)",
        "- Failed: $($failed.Count)",
        '',
        '| Database | Result | Detail |',
        '|---|---|---|'
    )
    foreach ($result in $Results) {
        $detail = if ($result.Success) {
            [string]$result.Status
        }
        else {
            ([string]$result.Error -replace '\|', '\|' -replace '\r?\n', ' ').Trim()
        }
        $outcome = if ($result.Success) { 'success' } else { 'failure' }
        $lines += "| $($result.DatabaseName) | $outcome | $detail |"
    }

    if ($failed.Count -gt 0) {
        $failedNames = $failed.DatabaseName -join ', '
        $lines += @('', "**Failed databases:** $failedNames")
        Write-Host "##vso[task.logissue type=error]Database deployment failures: $failedNames"
    }
    Write-Host "Database deployment summary: $($succeeded.Count) succeeded, $($failed.Count) failed."

    if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
        $summaryDirectory = Split-Path -Parent $SummaryPath
        if ($summaryDirectory) {
            New-Item -ItemType Directory -Force -Path $summaryDirectory | Out-Null
        }
        Add-Content -Path $SummaryPath -Value $lines -Encoding utf8
    }
}

Export-ModuleMember -Function @(
    'Resolve-DatabaseNames',
    'Get-DatabaseRollout',
    'Test-DeployReportHasChanges',
    'Get-DacFxPostDeploymentPayload',
    'Invoke-DatabaseFanOut',
    'Write-DatabaseDeploymentSummary'
)
