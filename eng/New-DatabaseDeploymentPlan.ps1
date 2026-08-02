[CmdletBinding(DefaultParameterSetName = 'TokenProvider')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$ServerName,
    [ValidateRange(1, 65535)][int]$Port = 1433,
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
    [Parameter(Mandatory, ParameterSetName = 'StaticToken')]
    [string]$AccessToken,
    [Parameter(Mandatory, ParameterSetName = 'TokenProvider')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$AccessTokenProviderPath,
    [Parameter(Mandatory)][string]$ReviewPath,
    [ValidateRange(1, 2147483647)][int]$CommandTimeout = 3600,
    [switch]$ValidateAllDatabasePlans,
    [ValidateSet('Warn', 'Fail')][string]$DatabasePlanDriftPolicy = 'Warn',
    [string]$SummaryPath,
    [string]$EnvironmentName = 'unknown'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Phase2.Common.psm1') -Force

$targets = @(Resolve-DatabaseNames -DatabaseNames $DatabaseNames -DatabaseName $DatabaseName)
$representative = $targets[0]
if ($PSCmdlet.ParameterSetName -eq 'TokenProvider') {
    $tokenOutput = @(& $AccessTokenProviderPath -DatabaseName $representative)
    if ($tokenOutput.Count -ne 1 -or $tokenOutput[0] -isnot [string] -or -not $tokenOutput[0]) {
        throw 'The access token provider did not return one Azure SQL token.'
    }
    $AccessToken = [string]$tokenOutput[0]
}

function Invoke-PlanAction {
    param([string]$Action, [string]$Database, [string]$OutputPath)
    $connection = "Server=tcp:$ServerName,$Port;Initial Catalog=$Database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    $arguments = @(
        "/Action:$Action",
        "/SourceFile:$DacpacPath",
        "/TargetConnectionString:$connection",
        "/AccessToken:$AccessToken",
        "/OutputPath:$OutputPath",
        "/Profile:$PublishProfilePath",
        "/p:CommandTimeout=$CommandTimeout"
    )
    & $SqlPackagePath @arguments 2>&1 | ForEach-Object { Write-Host "[$Database][$Action] $_" }
    if ($LASTEXITCODE -ne 0) {
        throw "$Action generation failed for '$Database' with exit code $LASTEXITCODE."
    }
}

New-Item -ItemType Directory -Force -Path $ReviewPath | Out-Null
$reportPath = Join-Path $ReviewPath 'deploy-report.xml'
$scriptPath = Join-Path $ReviewPath 'deploy.sql'
$policyPath = Join-Path $ReviewPath 'deployment-script-policy.md'
Invoke-PlanAction DeployReport $representative $reportPath
Invoke-PlanAction Script $representative $scriptPath
& (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') -ScriptPath $scriptPath -ReportPath $policyPath

$drifted = [Collections.Generic.List[string]]::new()
if ($ValidateAllDatabasePlans) {
    $reports = Join-Path $ReviewPath 'all-database-reports'
    $scripts = Join-Path $ReviewPath 'all-database-scripts'
    $policies = Join-Path $ReviewPath 'all-database-policy-reports'
    foreach ($path in @($reports, $scripts, $policies)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    Copy-Item $reportPath (Join-Path $reports "$representative.deploy-report.xml") -Force
    Copy-Item $scriptPath (Join-Path $scripts "$representative.deploy.sql") -Force
    Copy-Item $policyPath (Join-Path $policies "$representative.deployment-script-policy.md") -Force
    foreach ($database in @($targets | Select-Object -Skip 1)) {
        $databaseReport = Join-Path $reports "$database.deploy-report.xml"
        $databaseScript = Join-Path $scripts "$database.deploy.sql"
        $databasePolicy = Join-Path $policies "$database.deployment-script-policy.md"
        Invoke-PlanAction DeployReport $database $databaseReport
        Invoke-PlanAction Script $database $databaseScript
        & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
            -ScriptPath $databaseScript `
            -ReportPath $databasePolicy
        try {
            & (Join-Path $PSScriptRoot 'Confirm-DeploymentPlan.ps1') `
                -ApprovedReportPath $reportPath `
                -CurrentReportPath $databaseReport `
                -CompareOperationsOnly
        }
        catch {
            $drifted.Add($database)
            $type = if ($DatabasePlanDriftPolicy -eq 'Fail') { 'error' } else { 'warning' }
            Write-Host "##vso[task.logissue type=$type]Database '$database' differs from '$representative'."
        }
    }
}
else {
    Write-Host '##vso[task.logissue type=warning]Only the representative database plan was generated.'
}
if ($DatabasePlanDriftPolicy -eq 'Fail' -and $drifted.Count -gt 0) {
    throw "All-database plan validation failed for: $($drifted -join ', ')"
}

[ordered]@{
    metadataVersion = 1
    environment = $EnvironmentName
    representativeDatabase = $representative
    targetDatabases = $targets
    allDatabasePlansValidated = [bool]$ValidateAllDatabasePlans
    driftPolicy = $DatabasePlanDriftPolicy
} | ConvertTo-Json | Set-Content (Join-Path $ReviewPath 'target-databases.json') -Encoding utf8

if ($SummaryPath) {
    Add-Content $SummaryPath @(
        "## Database plan summary: $EnvironmentName", '',
        "- Representative database: $representative",
        "- Target database count: $($targets.Count)",
        "- All-database validation: $([bool]$ValidateAllDatabasePlans)",
        "- Different plans: $(if ($drifted.Count) { $drifted -join ', ' } else { 'none' })"
    ) -Encoding utf8
}
Write-Host "Representative deployment plan created for '$representative'."
