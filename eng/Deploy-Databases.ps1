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
    [ValidateNotNullOrEmpty()]
    [string]$AccessToken,
    [ValidateRange(1, 2147483647)]
    [int]$CommandTimeout = 3600,
    [ValidateRange(1, 64)]
    [int]$MaxParallel = 4,
    [string]$TestPath,
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
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

$targets = @(
    Resolve-DatabaseNames `
        -DatabaseNames $DatabaseNames `
        -DatabaseName $DatabaseName
)
$rollout = Get-DatabaseRollout -DatabaseNames $targets
Write-Host "Canary database: $($rollout.Canary)"
Write-Host "Remaining databases: $($rollout.Remaining.Count); maxParallel: $MaxParallel"

$context = [pscustomobject]@{
    ServerName = $ServerName
    Port = $Port
    DacpacPath = (Resolve-Path $DacpacPath).Path
    PublishProfilePath = (Resolve-Path $PublishProfilePath).Path
    SqlPackagePath = (Resolve-Path $SqlPackagePath).Path
    ApprovedReportPath = (Resolve-Path $ApprovedReportPath).Path
    ApprovedReportsDirectory = Join-Path (Split-Path -Parent (Resolve-Path $ApprovedReportPath).Path) 'all-database-reports'
    AccessToken = $AccessToken
    CommandTimeout = $CommandTimeout
    TestPath = (Resolve-Path $TestPath).Path
    ReportDirectory = (Resolve-Path $ReportDirectory).Path
    RepresentativeDatabase = $rollout.Canary
    ModulePath = $modulePath
    ConfirmScript = $confirmScript
    TestScript = $testScript
}

$worker = {
    param($Database, $WorkerContext)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Import-Module $WorkerContext.ModulePath -Force

    try {
        $reportPath = Join-Path $WorkerContext.ReportDirectory "$Database.deploy-report.xml"
        $connection = "Server=tcp:$($WorkerContext.ServerName),$($WorkerContext.Port);Initial Catalog=$Database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
        $reportArguments = @(
            '/Action:DeployReport',
            "/SourceFile:$($WorkerContext.DacpacPath)",
            "/TargetConnectionString:$connection",
            "/AccessToken:$($WorkerContext.AccessToken)",
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
            $comparisonReport = if (Test-Path $databaseApprovedReport -PathType Leaf) {
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

            $publishArguments = @(
                '/Action:Publish',
                "/SourceFile:$($WorkerContext.DacpacPath)",
                "/TargetConnectionString:$connection",
                "/AccessToken:$($WorkerContext.AccessToken)",
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

        & $WorkerContext.TestScript `
            -ServerName $WorkerContext.ServerName `
            -Port $WorkerContext.Port `
            -DatabaseName $Database `
            -AccessToken $WorkerContext.AccessToken `
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
