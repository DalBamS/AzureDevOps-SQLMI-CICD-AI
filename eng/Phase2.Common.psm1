Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-DatabaseNames {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$DatabaseNames,
        [AllowEmptyString()][string]$DatabaseName
    )
    $source = if ($DatabaseNames -and $DatabaseNames -notmatch '^\$\(') {
        $DatabaseNames
    } elseif ($DatabaseName -and $DatabaseName -notmatch '^\$\(') {
        $DatabaseName
    } else {
        throw 'Set databaseNames or databaseName.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $result = @(
        foreach ($candidate in $source.Split(',')) {
            $name = $candidate.Trim()
            if ($name -notmatch '^[A-Za-z0-9_-]+$') {
                throw "Invalid database name '$name'."
            }
            if ($seen.Add($name)) { $name }
        }
    )
    if ($result.Count -eq 0) { throw 'No target databases were resolved.' }
    return $result
}

function Get-DatabaseRollout {
    param([Parameter(Mandatory)][string[]]$DatabaseNames)
    return [pscustomobject]@{
        Canary = $DatabaseNames[0]
        Remaining = @($DatabaseNames | Select-Object -Skip 1)
    }
}

function Test-DeployReportHasChanges {
    param([Parameter(Mandatory)][string]$Path)
    [xml]$report = Get-Content $Path -Raw
    return $report.SelectNodes("//*[local-name()='Operation']").Count -gt 0
}

function Invoke-DatabaseFanOut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$DatabaseNames,
        [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][psobject]$Context,
        [ValidateRange(1, 64)][int]$MaxParallel = 4
    )
    if ($DatabaseNames.Count -eq 0) { return @() }
    $jobs = @(
        foreach ($database in $DatabaseNames) {
            Start-ThreadJob `
                -ThrottleLimit $MaxParallel `
                -ScriptBlock $Operation `
                -ArgumentList $database, $Context
        }
    )
    try {
        [void](Wait-Job $jobs)
        return @(
            foreach ($job in $jobs) {
                $database = $DatabaseNames[[array]::IndexOf($jobs, $job)]
                try {
                    $result = @(
                        Receive-Job $job -ErrorAction Stop |
                            Where-Object { $_.PSObject.Properties['DatabaseName'] }
                    ) | Select-Object -Last 1
                    if (-not $result) { throw 'Worker returned no deployment result.' }
                    $result
                }
                catch {
                    [pscustomobject]@{
                        DatabaseName = $database
                        Success = $false
                        Status = 'Failed'
                        Error = $_.Exception.Message
                    }
                }
            }
        )
    }
    finally {
        Remove-Job $jobs -Force -ErrorAction SilentlyContinue
    }
}

function Write-DatabaseDeploymentSummary {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [AllowEmptyString()][string]$SummaryPath,
        [Parameter(Mandatory)][string]$EnvironmentName
    )
    $failed = @($Results | Where-Object { -not $_.Success })
    $lines = @(
        "## Database deployment summary: $EnvironmentName", '',
        "- Total: $($Results.Count)",
        "- Succeeded: $($Results.Count - $failed.Count)",
        "- Failed: $($failed.Count)", '',
        '| Database | Result | Detail |',
        '|---|---|---|'
    )
    foreach ($result in $Results) {
        $outcome = if ($result.Success) { 'success' } else { 'failure' }
        $detail = if ($result.Success) { $result.Status } else { $result.Error }
        $lines += "| $($result.DatabaseName) | $outcome | $($detail -replace '\|', '\|' -replace '\r?\n', ' ') |"
    }
    if ($SummaryPath) {
        $directory = Split-Path -Parent $SummaryPath
        if ($directory) { New-Item -ItemType Directory -Force $directory | Out-Null }
        Add-Content $SummaryPath $lines -Encoding utf8
    }
    if ($failed.Count -gt 0) {
        Write-Host "##vso[task.logissue type=error]Database deployment failures: $($failed.DatabaseName -join ', ')"
    }
}

Export-ModuleMember -Function @(
    'Resolve-DatabaseNames',
    'Get-DatabaseRollout',
    'Test-DeployReportHasChanges',
    'Invoke-DatabaseFanOut',
    'Write-DatabaseDeploymentSummary'
)
