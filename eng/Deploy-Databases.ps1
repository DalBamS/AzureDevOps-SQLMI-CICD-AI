[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$ServerName,
    [ValidateRange(1, 65535)]
    [int]$Port = 1433,
    [AllowEmptyString()][string]$DatabaseName,
    [AllowEmptyString()][string]$DatabaseNames,
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
    [ValidateSet('Publish', 'ValidatedScript')]
    [string]$DeploymentMode = 'Publish',
    [ValidateRange(1, 2147483647)]
    [int]$CommandTimeout = 3600,
    [ValidateRange(1, 1440)]
    [int]$MinimumTokenLifetimeMinutes = 20,
    [ValidateRange(1, 64)]
    [int]$MaxParallel = 4,
    [switch]$ValidateAllDatabasePlans,
    [string]$TestPath,
    [string]$SmokeTestScriptPath,
    [string]$DeploymentScriptExecutorPath,
    [string]$ReportDirectory,
    [string]$SummaryPath,
    [string]$EnvironmentName = 'unknown'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$modulePath = Join-Path $PSScriptRoot 'Phase2.Common.psm1'
Import-Module $modulePath -Force

function Get-AccessTokenRemainingMinutes {
    param([Parameter(Mandatory)][string]$AccessToken)

    $segments = $AccessToken.Split('.')
    if ($segments.Count -lt 2) {
        throw 'The access token is not a JWT with a payload segment.'
    }
    $payloadSegment = $segments[1].Replace('-', '+').Replace('_', '/')
    switch ($payloadSegment.Length % 4) {
        2 { $payloadSegment += '==' }
        3 { $payloadSegment += '=' }
    }
    $payloadJson = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($payloadSegment)
    )
    $payload = $payloadJson | ConvertFrom-Json
    if (-not $payload.PSObject.Properties['exp']) {
        throw "The access token payload does not contain an 'exp' claim."
    }
    $expiresAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$payload.exp)
    return ($expiresAt - [DateTimeOffset]::UtcNow).TotalMinutes
}

function Write-AccessTokenPreflightSummary {
    param([Parameter(Mandatory)][string]$Message)

    if (-not $SummaryPath) { return }
    $directory = Split-Path -Parent $SummaryPath
    if ($directory) { New-Item -ItemType Directory -Force $directory | Out-Null }
    Add-Content -Path $SummaryPath -Encoding utf8 -Value @(
        '## Azure SQL access token preflight',
        '',
        "- $Message",
        ''
    )
}

if (-not $TestPath) {
    $TestPath = Join-Path $repoRoot 'tests/integration'
}
if (-not $SmokeTestScriptPath) {
    $SmokeTestScriptPath = Join-Path $PSScriptRoot 'Test-DeployedDatabase.ps1'
}
if (-not $DeploymentScriptExecutorPath) {
    $DeploymentScriptExecutorPath = Join-Path $PSScriptRoot 'Invoke-ValidatedDeploymentScript.ps1'
}
if (-not $ReportDirectory) {
    $ReportDirectory = Join-Path $repoRoot 'artifacts/deployment-reports'
}
foreach ($path in @($TestPath, $SmokeTestScriptPath, $DeploymentScriptExecutorPath)) {
    if (-not (Test-Path $path)) { throw "Required deployment path not found: $path" }
}
New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

$targets = @(Resolve-DatabaseNames -DatabaseNames $DatabaseNames -DatabaseName $DatabaseName)
$rollout = Get-DatabaseRollout -DatabaseNames $targets
if (
    $DeploymentMode -eq 'ValidatedScript' -and
    $targets.Count -gt 1 -and
    -not $ValidateAllDatabasePlans
) {
    throw 'ValidatedScript mode requires per-database approved scripts for a multi-database rollout. Enable ValidateAllDatabasePlans.'
}

$tokenOutput = @(& $AccessTokenProviderPath -DatabaseName $rollout.Canary)
if (
    $tokenOutput.Count -ne 1 -or
    $tokenOutput[0] -isnot [string] -or
    [string]::IsNullOrWhiteSpace([string]$tokenOutput[0])
) {
    throw 'The access token provider did not return exactly one Azure SQL token.'
}
$accessToken = [string]$tokenOutput[0]
$remainingTokenMinutes = $null
try {
    $remainingTokenMinutes = Get-AccessTokenRemainingMinutes -AccessToken $accessToken
}
catch {
    $message = "Unable to read the Azure SQL access token expiration; deployment will continue: $($_.Exception.Message)"
    Write-Warning $message
    Write-AccessTokenPreflightSummary -Message $message
}
if ($null -ne $remainingTokenMinutes) {
    $remainingText = $remainingTokenMinutes.ToString(
        'F1',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $message = "Remaining lifetime at rollout start: $remainingText minute(s); required minimum: $MinimumTokenLifetimeMinutes minute(s)."
    Write-Host $message
    Write-AccessTokenPreflightSummary -Message $message
    if ($remainingTokenMinutes -lt $MinimumTokenLifetimeMinutes) {
        throw "Azure SQL access token remaining lifetime is below the required minimum. SqlPackage was not invoked."
    }
}

$approvedRoot = Split-Path -Parent (Resolve-Path $ApprovedReportPath).Path
$context = [pscustomobject]@{
    ServerName = $ServerName
    Port = $Port
    DacpacPath = (Resolve-Path $DacpacPath).Path
    PublishProfilePath = (Resolve-Path $PublishProfilePath).Path
    SqlPackagePath = (Resolve-Path $SqlPackagePath).Path
    ApprovedReportPath = (Resolve-Path $ApprovedReportPath).Path
    ApprovedRoot = $approvedRoot
    AccessToken = $accessToken
    DeploymentMode = $DeploymentMode
    CommandTimeout = $CommandTimeout
    ValidateAllDatabasePlans = [bool]$ValidateAllDatabasePlans
    RepresentativeDatabase = $rollout.Canary
    ReportDirectory = (Resolve-Path $ReportDirectory).Path
    ConfirmScript = (Resolve-Path (Join-Path $PSScriptRoot 'Confirm-DeploymentPlan.ps1')).Path
    PolicyScript = (Resolve-Path (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1')).Path
    Executor = (Resolve-Path $DeploymentScriptExecutorPath).Path
    SmokeTest = (Resolve-Path $SmokeTestScriptPath).Path
    TestPath = (Resolve-Path $TestPath).Path
}

$worker = {
    param($Database, $WorkerContext)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    function Invoke-WorkerSqlPackage {
        param([string]$Action, [string]$OutputPath)
        $connection = "Server=tcp:$($WorkerContext.ServerName),$($WorkerContext.Port);Initial Catalog=$Database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
        $arguments = @(
            "/Action:$Action",
            "/SourceFile:$($WorkerContext.DacpacPath)",
            "/TargetConnectionString:$connection",
            "/AccessToken:$($WorkerContext.AccessToken)",
            "/Profile:$($WorkerContext.PublishProfilePath)",
            "/p:CommandTimeout=$($WorkerContext.CommandTimeout)"
        )
        if ($OutputPath) { $arguments += "/OutputPath:$OutputPath" }
        & $WorkerContext.SqlPackagePath @arguments 2>&1 |
            ForEach-Object { Write-Host "[$Database][$Action] $_" }
        if ($LASTEXITCODE -ne 0) {
            throw "SqlPackage $Action failed for '$Database' with exit code $LASTEXITCODE."
        }
    }

    try {
        $reportPath = Join-Path $WorkerContext.ReportDirectory "$Database.deploy-report.xml"
        Invoke-WorkerSqlPackage -Action DeployReport -OutputPath $reportPath
        $approvedReport = if ($WorkerContext.ValidateAllDatabasePlans) {
            Join-Path $WorkerContext.ApprovedRoot "all-database-reports/$Database.deploy-report.xml"
        } else {
            $WorkerContext.ApprovedReportPath
        }
        $compareOperations = (
            -not $WorkerContext.ValidateAllDatabasePlans -and
            $Database -ne $WorkerContext.RepresentativeDatabase
        )
        & $WorkerContext.ConfirmScript `
            -ApprovedReportPath $approvedReport `
            -CurrentReportPath $reportPath `
            -CompareOperationsOnly:$compareOperations

        if ($WorkerContext.DeploymentMode -eq 'Publish') {
            Invoke-WorkerSqlPackage -Action Publish -OutputPath ''
        }
        else {
            $scriptPath = Join-Path $WorkerContext.ReportDirectory "$Database.deploy.sql"
            $policyPath = Join-Path $WorkerContext.ReportDirectory "$Database.deployment-policy.md"
            Invoke-WorkerSqlPackage -Action Script -OutputPath $scriptPath
            & $WorkerContext.PolicyScript -ScriptPath $scriptPath -ReportPath $policyPath
            $approvedScript = if ($WorkerContext.ValidateAllDatabasePlans) {
                Join-Path $WorkerContext.ApprovedRoot "all-database-scripts/$Database.deploy.sql"
            } else {
                Join-Path $WorkerContext.ApprovedRoot 'deploy.sql'
            }
            if (
                -not (Test-Path $approvedScript -PathType Leaf) -or
                [IO.File]::ReadAllText($approvedScript) -cne [IO.File]::ReadAllText($scriptPath)
            ) {
                throw "Current deployment script for '$Database' differs from the approved script."
            }
            $hashMatch = [regex]::Match(
                (Get-Content $policyPath -Raw),
                '(?m)^- Sanitized SQL SHA-256: (?<hash>[A-F0-9]{64})\s*$'
            )
            if (-not $hashMatch.Success) {
                throw 'Deployment policy report is missing the sanitized SQL hash.'
            }
            & $WorkerContext.Executor `
                -ServerName $WorkerContext.ServerName `
                -Port $WorkerContext.Port `
                -DatabaseName $Database `
                -AccessToken $WorkerContext.AccessToken `
                -ScriptPath $scriptPath `
                -ExpectedSanitizedSha256 $hashMatch.Groups['hash'].Value `
                -CommandTimeout $WorkerContext.CommandTimeout
        }

        & $WorkerContext.SmokeTest `
            -ServerName $WorkerContext.ServerName `
            -Port $WorkerContext.Port `
            -DatabaseName $Database `
            -AccessToken $WorkerContext.AccessToken `
            -TestPath $WorkerContext.TestPath
        return [pscustomobject]@{
            DatabaseName = $Database
            Success = $true
            Status = "$($WorkerContext.DeploymentMode) succeeded; smoke test passed"
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

Write-Host "Deployment mode: $DeploymentMode; canary: $($rollout.Canary); maxParallel: $MaxParallel"
$results = [Collections.Generic.List[object]]::new()
$canary = @(Invoke-DatabaseFanOut -DatabaseNames @($rollout.Canary) -Operation $worker -Context $context -MaxParallel 1)
foreach ($result in $canary) { $results.Add($result) }
if (@($canary | Where-Object { -not $_.Success }).Count -gt 0) {
    Write-DatabaseDeploymentSummary -Results $results -SummaryPath $SummaryPath -EnvironmentName $EnvironmentName
    throw "Canary deployment failed for '$($rollout.Canary)': $($canary[0].Error)"
}
if ($rollout.Remaining.Count -gt 0) {
    $remaining = @(
        Invoke-DatabaseFanOut `
            -DatabaseNames $rollout.Remaining `
            -Operation $worker `
            -Context $context `
            -MaxParallel $MaxParallel
    )
    foreach ($result in $remaining) { $results.Add($result) }
}
Write-DatabaseDeploymentSummary -Results $results -SummaryPath $SummaryPath -EnvironmentName $EnvironmentName
$failed = @($results | Where-Object { -not $_.Success })
if ($failed.Count -gt 0) {
    throw "Database rollout failed for: $($failed.DatabaseName -join ', ')"
}
