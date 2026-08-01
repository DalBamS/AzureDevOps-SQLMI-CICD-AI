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
    'Invoke-DatabaseFanOut',
    'Write-DatabaseDeploymentSummary'
)
