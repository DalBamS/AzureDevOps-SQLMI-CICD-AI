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
    [switch]$ValidateAllDatabasePlans,
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
$policyScript = Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1'
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
if (-not (Test-Path $metadataPath -PathType Leaf)) {
    throw "Approved deployment manifest is required: $metadataPath"
}
try {
    $metadata = Get-Content -Path $metadataPath -Raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "Approved deployment manifest is invalid JSON: $($_.Exception.Message)"
}
foreach ($requiredProperty in @(
    'manifestVersion',
    'environment',
    'representativeDatabase',
    'targetDatabases',
    'allDatabasePlansValidated',
    'allDatabaseScriptsGated',
    'gatedDatabases',
    'dacpacSha256',
    'artifacts'
)) {
    if ($null -eq $metadata.PSObject.Properties[$requiredProperty]) {
        throw "Approved deployment manifest is missing '$requiredProperty'."
    }
}
$manifestVersionType = [Type]::GetTypeCode($metadata.manifestVersion.GetType())
if (
    $manifestVersionType -notin @(
        [TypeCode]::SByte,
        [TypeCode]::Byte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64
    ) -or
    [int64]$metadata.manifestVersion -ne 3
) {
    throw "Approved deployment manifest version '$($metadata.manifestVersion)' is not supported."
}
if ([string]$metadata.environment -cne $EnvironmentName) {
    throw 'Approved deployment manifest environment does not match the runtime environment.'
}
$metadataTargets = @($metadata.targetDatabases | ForEach-Object { [string]$_ })
if (
    [string]$metadata.representativeDatabase -cne $rollout.Canary -or
    $metadataTargets.Count -ne $targets.Count -or
    (Compare-Object -ReferenceObject $targets -DifferenceObject $metadataTargets -SyncWindow 0)
) {
    throw 'Approved deployment manifest does not match the requested database rollout.'
}
if (
    $metadata.allDatabasePlansValidated -isnot [bool] -or
    [bool]$metadata.allDatabasePlansValidated -ne [bool]$ValidateAllDatabasePlans
) {
    throw 'Approved deployment manifest validation mode does not match the runtime mode.'
}
$expectedGatedDatabases = @(
    if ($ValidateAllDatabasePlans) { $targets } else { $rollout.Canary }
)
$gatedDatabases = @($metadata.gatedDatabases | ForEach-Object { [string]$_ })
if (
    $metadata.allDatabaseScriptsGated -isnot [bool] -or
    [bool]$metadata.allDatabaseScriptsGated -ne [bool]$ValidateAllDatabasePlans -or
    $gatedDatabases.Count -ne $expectedGatedDatabases.Count -or
    (Compare-Object -ReferenceObject $expectedGatedDatabases -DifferenceObject $gatedDatabases -SyncWindow 0)
) {
    throw 'Approved deployment manifest gated database contract does not match the runtime mode.'
}
if (
    [string]$metadata.dacpacSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
    (Get-FileHash -Path $DacpacPath -Algorithm SHA256).Hash -cne ([string]$metadata.dacpacSha256).ToUpperInvariant()
) {
    throw 'Downloaded DACPAC does not match the approved deployment manifest.'
}

$expectedArtifacts = [ordered]@{
    ('representativeReport|' + $rollout.Canary) = 'deploy-report.xml'
    ('representativeScript|' + $rollout.Canary) = 'deploy.sql'
    ('representativePolicy|' + $rollout.Canary) = 'deployment-script-policy.md'
}
if ($ValidateAllDatabasePlans) {
    foreach ($database in $targets) {
        $expectedArtifacts["databaseReport|$database"] = "all-database-reports/$database.deploy-report.xml"
        $expectedArtifacts["databaseScript|$database"] = "all-database-scripts/$database.deploy.sql"
        $expectedArtifacts["databasePolicy|$database"] = "all-database-policy-reports/$database.deployment-script-policy.md"
    }
}
$manifestArtifacts = @($metadata.artifacts)
if ($manifestArtifacts.Count -ne $expectedArtifacts.Count) {
    throw 'Approved deployment manifest contains an unexpected artifact set.'
}
$seenArtifactPaths = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$approvedArtifactPaths = @{}
foreach ($artifact in $manifestArtifacts) {
    foreach ($property in @('kind', 'database', 'path', 'sha256')) {
        if ($null -eq $artifact.PSObject.Properties[$property]) {
            throw "Approved deployment manifest artifact is missing '$property'."
        }
    }
    $relativePath = ([string]$artifact.path).Replace('\', '/')
    if (
        [string]::IsNullOrWhiteSpace($relativePath) -or
        [IO.Path]::IsPathRooted($relativePath) -or
        $relativePath -eq '..' -or
        $relativePath.StartsWith('../') -or
        -not $seenArtifactPaths.Add($relativePath)
    ) {
        throw "Approved deployment manifest contains an unsafe or duplicate artifact path: $relativePath"
    }
    $artifactKey = "$([string]$artifact.kind)|$([string]$artifact.database)"
    if (
        -not $expectedArtifacts.Contains($artifactKey) -or
        $expectedArtifacts[$artifactKey] -cne $relativePath
    ) {
        throw "Approved deployment manifest contains an unexpected artifact: $artifactKey"
    }
    $artifactPath = [IO.Path]::GetFullPath((Join-Path $approvedReviewPath $relativePath))
    $reviewRootPrefix = [IO.Path]::GetFullPath($approvedReviewPath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if (
        -not $artifactPath.StartsWith($reviewRootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path $artifactPath -PathType Leaf) -or
        [string]$artifact.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        (Get-FileHash -Path $artifactPath -Algorithm SHA256).Hash -cne ([string]$artifact.sha256).ToUpperInvariant()
    ) {
        throw "Approved deployment artifact failed path or SHA-256 validation: $relativePath"
    }
    $approvedArtifactPaths[$artifactKey] = $artifactPath
}
if ((Resolve-Path $ApprovedReportPath).Path -cne $approvedArtifactPaths["representativeReport|$($rollout.Canary)"]) {
    throw 'ApprovedReportPath does not match the manifest representative report.'
}
$usePerDatabaseApprovedReports = [bool]$ValidateAllDatabasePlans

$context = [pscustomobject]@{
    ServerName = $ServerName
    Port = $Port
    DacpacPath = (Resolve-Path $DacpacPath).Path
    PublishProfilePath = (Resolve-Path $PublishProfilePath).Path
    SqlPackagePath = (Resolve-Path $SqlPackagePath).Path
    ApprovedReportPath = $resolvedApprovedReportPath
    ApprovedReportsDirectory = $approvedReportsDirectory
    ApprovedScriptsDirectory = $approvedScriptsDirectory
    UsePerDatabaseApprovedReports = $usePerDatabaseApprovedReports
    AccessTokenProviderPath = (Resolve-Path $AccessTokenProviderPath).Path
    CommandTimeout = $CommandTimeout
    TestPath = (Resolve-Path $TestPath).Path
    ReportDirectory = (Resolve-Path $ReportDirectory).Path
    RepresentativeDatabase = $rollout.Canary
    ModulePath = $modulePath
    ConfirmScript = $confirmScript
    PolicyScript = $policyScript
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

    function Get-ComparableDeploymentScript {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$TargetDatabase
        )

        $content = Get-Content -Path $Path -Raw
        $escapedDatabase = [regex]::Escape($TargetDatabase)
        $content = [regex]::Replace(
            $content,
            "(?im)^(\s*Deployment script for\s+)$escapedDatabase(\s*)$",
            '${1}__TARGET_DATABASE__${2}'
        )
        $content = [regex]::Replace(
            $content,
            "(?im)^(\s*:setvar\s+DatabaseName\s+)`"$escapedDatabase`"(\s*)$",
            '${1}"__TARGET_DATABASE__"${2}'
        )
        return [regex]::Replace(
            $content,
            "(?im)^(\s*:setvar\s+DefaultFilePrefix\s+)`"$escapedDatabase`"(\s*)$",
            '${1}"__TARGET_DATABASE__"${2}'
        )
    }

    try {
        $reportPath = Join-Path $WorkerContext.ReportDirectory "$Database.deploy-report.xml"
        $scriptPath = Join-Path $WorkerContext.ReportDirectory "$Database.deploy.sql"
        $policyReportPath = Join-Path $WorkerContext.ReportDirectory "$Database.deployment-script-policy.md"
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

            $scriptAccessToken = Get-WorkerAccessToken
            $scriptArguments = @(
                '/Action:Script',
                "/SourceFile:$($WorkerContext.DacpacPath)",
                "/TargetConnectionString:$connection",
                "/AccessToken:$scriptAccessToken",
                "/OutputPath:$scriptPath",
                "/Profile:$($WorkerContext.PublishProfilePath)",
                "/p:CommandTimeout=$($WorkerContext.CommandTimeout)"
            )
            & $WorkerContext.SqlPackagePath @scriptArguments 2>&1 |
                ForEach-Object { Write-Host "[$Database] $_" }
            if ($LASTEXITCODE -ne 0) {
                throw "Current deployment script generation failed with exit code $LASTEXITCODE."
            }
            & $WorkerContext.PolicyScript `
                -ScriptPath $scriptPath `
                -ReportPath $policyReportPath

            $approvedScript = if ($WorkerContext.UsePerDatabaseApprovedReports) {
                Join-Path $WorkerContext.ApprovedScriptsDirectory "$Database.deploy.sql"
            }
            else {
                Join-Path (Split-Path -Parent $WorkerContext.ApprovedReportPath) 'deploy.sql'
            }
            $approvedScriptContent = if (
                -not $WorkerContext.UsePerDatabaseApprovedReports -and
                $Database -ne $WorkerContext.RepresentativeDatabase
            ) {
                Get-ComparableDeploymentScript `
                    -Path $approvedScript `
                    -TargetDatabase $WorkerContext.RepresentativeDatabase
            }
            else {
                Get-Content -Path $approvedScript -Raw
            }
            $currentScriptContent = if (
                -not $WorkerContext.UsePerDatabaseApprovedReports -and
                $Database -ne $WorkerContext.RepresentativeDatabase
            ) {
                Get-ComparableDeploymentScript -Path $scriptPath -TargetDatabase $Database
            }
            else {
                Get-Content -Path $scriptPath -Raw
            }
            if ($approvedScriptContent -cne $currentScriptContent) {
                throw 'The target deployment script changed after approval. Generate and approve a new deployment plan.'
            }

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
