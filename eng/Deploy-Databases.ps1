[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$ServerName,
    [ValidateRange(1, 65535)]
    [int]$Port = 1433,
    [AllowEmptyString()]
    [string]$DatabaseName,
    [AllowEmptyString()]
    [string]$DatabaseNames,
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$DacpacPath,
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$PublishProfilePath,
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$SqlPackagePath,
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ApprovedReportPath,
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$AccessTokenProviderPath,
    [ValidateRange(1, 2147483647)]
    [int]$CommandTimeout = 3600,
    [ValidateRange(1, 64)]
    [int]$MaxParallel = 4,
    [string]$TestPath,
    [string]$SmokeTestScriptPath,
    [string]$ReportDirectory,
    [string]$SummaryPath,
    [string]$EnvironmentName = 'unknown'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$modulePath = Join-Path $PSScriptRoot 'Phase2.Common.psm1'
$confirmScript = Join-Path $PSScriptRoot 'Confirm-DeploymentPlan.ps1'
$testScript = Join-Path $PSScriptRoot 'Test-DeployedDatabase.ps1'
Import-Module $modulePath -Force

if (-not $TestPath) {
    $TestPath = [IO.Path]::Combine($repoRoot, 'tests', 'integration')
}
if (-not (Test-Path $TestPath -PathType Container)) {
    throw "Integration test directory not found: $TestPath"
}
if (-not $ReportDirectory) {
    $ReportDirectory = [IO.Path]::Combine($repoRoot, 'artifacts', 'deployment-reports')
}
if (-not $SmokeTestScriptPath) {
    $SmokeTestScriptPath = $testScript
}
if (-not (Test-Path $SmokeTestScriptPath -PathType Leaf)) {
    throw "Smoke test script not found: $SmokeTestScriptPath"
}
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

$targets = @(
    Resolve-DatabaseNames `
        -DatabaseNames $DatabaseNames `
        -DatabaseName $DatabaseName
)
$rollout = Get-DatabaseRollout -DatabaseNames $targets
Write-Host "Canary database: $($rollout.Canary)"
Write-Host "Remaining databases: $($rollout.Remaining.Count); maxParallel: $MaxParallel"

$resolvedApprovedReportPath = (Resolve-Path $ApprovedReportPath).Path
$approvedReviewPath = Split-Path -Parent $resolvedApprovedReportPath
$approvedReportsDirectory = Join-Path $approvedReviewPath 'all-database-reports'
$approvedScriptsDirectory = Join-Path $approvedReviewPath 'all-database-scripts'
$approvedPolicyReportsDirectory = Join-Path $approvedReviewPath 'all-database-policy-reports'
$metadataPath = Join-Path $approvedReviewPath 'target-databases.json'
$usePerDatabaseApprovedReports = $false
if (Test-Path $metadataPath -PathType Leaf) {
    try {
        $metadata = Get-Content -Path $metadataPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Approved target metadata is invalid JSON: $($_.Exception.Message)"
    }
    if (
        $null -eq $metadata.PSObject.Properties['representativeDatabase'] -or
        $null -eq $metadata.PSObject.Properties['targetDatabases'] -or
        $null -eq $metadata.PSObject.Properties['allDatabasePlansValidated']
    ) {
        throw 'Approved target metadata is missing required deployment plan fields.'
    }
    $metadataTargets = @($metadata.targetDatabases | ForEach-Object { [string]$_ })
    if (
        [string]$metadata.representativeDatabase -cne $rollout.Canary -or
        $metadataTargets.Count -ne $targets.Count -or
        (Compare-Object -ReferenceObject $targets -DifferenceObject $metadataTargets -SyncWindow 0)
    ) {
        throw 'Approved target metadata does not match the requested database rollout.'
    }
    if ($metadata.allDatabasePlansValidated -isnot [bool]) {
        throw 'Approved target metadata has an invalid allDatabasePlansValidated value.'
    }
    $usePerDatabaseApprovedReports = [bool]$metadata.allDatabasePlansValidated
    if ($usePerDatabaseApprovedReports) {
        if (
            $null -eq $metadata.PSObject.Properties['allDatabaseScriptsGated'] -or
            $metadata.allDatabaseScriptsGated -isnot [bool] -or
            -not [bool]$metadata.allDatabaseScriptsGated -or
            $null -eq $metadata.PSObject.Properties['gatedDatabases']
        ) {
            throw 'Approved target metadata does not confirm that every database deployment script passed the policy gate.'
        }
        $gatedDatabases = @($metadata.gatedDatabases | ForEach-Object { [string]$_ })
        if (
            $gatedDatabases.Count -ne $targets.Count -or
            (Compare-Object -ReferenceObject $targets -DifferenceObject $gatedDatabases -SyncWindow 0)
        ) {
            throw 'Approved target metadata gated database list does not match the requested rollout.'
        }
        if (-not (Test-Path $approvedReportsDirectory -PathType Container)) {
            throw 'Approved target metadata requires per-database reports, but the report directory is missing.'
        }
        foreach ($database in $targets) {
            $databaseReportPath = Join-Path $approvedReportsDirectory "$database.deploy-report.xml"
            $databaseScriptPath = Join-Path $approvedScriptsDirectory "$database.deploy.sql"
            $databasePolicyReportPath = Join-Path $approvedPolicyReportsDirectory "$database.deployment-script-policy.md"
            if (
                -not (Test-Path $databaseReportPath -PathType Leaf) -or
                -not (Test-Path $databaseScriptPath -PathType Leaf) -or
                -not (Test-Path $databasePolicyReportPath -PathType Leaf)
            ) {
                throw "Approved gated plan artifacts are incomplete for '$database'."
            }
        }
    }
}

$context = [pscustomobject]@{
    ServerName = $ServerName
    Port = $Port
    DacpacPath = (Resolve-Path $DacpacPath).Path
    PublishProfilePath = (Resolve-Path $PublishProfilePath).Path
    SqlPackagePath = (Resolve-Path $SqlPackagePath).Path
    ApprovedReportPath = $resolvedApprovedReportPath
    ApprovedReportsDirectory = $approvedReportsDirectory
    UsePerDatabaseApprovedReports = $usePerDatabaseApprovedReports
    AccessTokenProviderPath = (Resolve-Path $AccessTokenProviderPath).Path
    CommandTimeout = $CommandTimeout
    TestPath = (Resolve-Path $TestPath).Path
    ReportDirectory = (Resolve-Path $ReportDirectory).Path
    RepresentativeDatabase = $rollout.Canary
    ModulePath = $modulePath
    ConfirmScript = $confirmScript
    TestScript = (Resolve-Path $SmokeTestScriptPath).Path
}

$worker = {
    param($Database, $WorkerContext)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module $WorkerContext.ModulePath -Force

    function Get-WorkerAccessToken {
        $providerOutput = @(
            & $WorkerContext.AccessTokenProviderPath -DatabaseName $Database
        )
        if (
            $providerOutput.Count -ne 1 -or
            $providerOutput[0] -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$providerOutput[0])
        ) {
            throw "The access token provider did not return exactly one token for '$Database'."
        }
        return [string]$providerOutput[0]
    }

    try {
        $reportPath = Join-Path $WorkerContext.ReportDirectory "$Database.deploy-report.xml"
        $connection = "Server=tcp:$($WorkerContext.ServerName),$($WorkerContext.Port);Initial Catalog=$Database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
        $reportAccessToken = Get-WorkerAccessToken
        $reportArguments = @(
            '/Action:DeployReport',
            "/SourceFile:$($WorkerContext.DacpacPath)",
            "/TargetConnectionString:$connection",
            "/AccessToken:$reportAccessToken",
            "/OutputPath:$reportPath",
            "/Profile:$($WorkerContext.PublishProfilePath)",
            "/p:CommandTimeout=$($WorkerContext.CommandTimeout)"
        )
        & $WorkerContext.SqlPackagePath @reportArguments 2>&1 |
            ForEach-Object { Write-Host "[$Database] $_" }
        if ($LASTEXITCODE -ne 0) {
            throw "Current deployment report generation failed with exit code $LASTEXITCODE."
        }

        $status = 'AlreadyCurrent'
        if (Test-DeployReportHasChanges -Path $reportPath) {
            $databaseApprovedReport = Join-Path `
                $WorkerContext.ApprovedReportsDirectory `
                "$Database.deploy-report.xml"
            $comparisonReport = if ($WorkerContext.UsePerDatabaseApprovedReports) {
                $databaseApprovedReport
            }
            else {
                $WorkerContext.ApprovedReportPath
            }
            & $WorkerContext.ConfirmScript `
                -ApprovedReportPath $comparisonReport `
                -CurrentReportPath $reportPath `
                -CompareOperationsOnly:(
                    $comparisonReport -eq $WorkerContext.ApprovedReportPath -and
                    $Database -ne $WorkerContext.RepresentativeDatabase
                )

            $publishAccessToken = Get-WorkerAccessToken
            $publishArguments = @(
                '/Action:Publish',
                "/SourceFile:$($WorkerContext.DacpacPath)",
                "/TargetConnectionString:$connection",
                "/AccessToken:$publishAccessToken",
                "/Profile:$($WorkerContext.PublishProfilePath)",
                "/p:CommandTimeout=$($WorkerContext.CommandTimeout)"
            )
            & $WorkerContext.SqlPackagePath @publishArguments 2>&1 |
                ForEach-Object { Write-Host "[$Database] $_" }
            if ($LASTEXITCODE -ne 0) {
                throw "DACPAC deployment failed with exit code $LASTEXITCODE."
            }
            $status = 'Deployed'
        }
        else {
            Write-Host "[$Database] Target already matches the approved DACPAC; publish is skipped."
        }

        $smokeTestAccessToken = Get-WorkerAccessToken
        & $WorkerContext.TestScript `
            -ServerName $WorkerContext.ServerName `
            -Port $WorkerContext.Port `
            -DatabaseName $Database `
            -AccessToken $smokeTestAccessToken `
            -TestPath $WorkerContext.TestPath

        return [pscustomobject]@{
            DatabaseName = $Database
            Success = $true
            Status = "$status; smoke test passed"
            Error = ''
        }
    }
    catch {
        return [pscustomobject]@{
            DatabaseName = $Database
            Success = $false
            Status = 'Failed'
            Error = $_.Exception.Message
        }
    }
}

$results = [System.Collections.Generic.List[object]]::new()
$canaryResult = @(
    Invoke-DatabaseFanOut `
        -DatabaseNames @($rollout.Canary) `
        -Operation $worker `
        -Context $context `
        -MaxParallel 1
)
foreach ($result in $canaryResult) {
    $results.Add($result)
}

if (@($canaryResult | Where-Object { -not $_.Success }).Count -gt 0) {
    Write-DatabaseDeploymentSummary `
        -Results $results.ToArray() `
        -SummaryPath $SummaryPath `
        -EnvironmentName $EnvironmentName
    throw "Canary deployment failed for '$($rollout.Canary)'; remaining databases were not started."
}

if ($rollout.Remaining.Count -gt 0) {
    Write-Host "Canary passed. Starting throttled deployment of the remaining databases."
    $remainingResults = @(
        Invoke-DatabaseFanOut `
            -DatabaseNames $rollout.Remaining `
            -Operation $worker `
            -Context $context `
            -MaxParallel $MaxParallel
    )
    foreach ($result in $remainingResults) {
        $results.Add($result)
    }
}

Write-DatabaseDeploymentSummary `
    -Results $results.ToArray() `
    -SummaryPath $SummaryPath `
    -EnvironmentName $EnvironmentName

$failed = @($results | Where-Object { -not $_.Success })
if ($failed.Count -gt 0) {
    throw "Database rollout failed for: $($failed.DatabaseName -join ', ')"
}
