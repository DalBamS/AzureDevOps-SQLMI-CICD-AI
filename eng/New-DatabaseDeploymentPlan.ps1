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
    [Parameter(Mandatory, ParameterSetName = 'StaticToken')]
    [ValidateNotNullOrEmpty()]
    [string]$AccessToken,
    [Parameter(Mandatory, ParameterSetName = 'TokenProvider')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$AccessTokenProviderPath,
    [Parameter(Mandatory)]
    [string]$ReviewPath,
    [ValidateRange(1, 2147483647)]
    [int]$CommandTimeout = 3600,
    [switch]$ValidateAllDatabasePlans,
    [ValidateSet('Warn', 'Fail')]
    [string]$DatabasePlanDriftPolicy = 'Warn',
    [string]$SummaryPath,
    [string]$EnvironmentName = 'unknown'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'Phase2.Common.psm1'
$confirmScript = Join-Path $PSScriptRoot 'Confirm-DeploymentPlan.ps1'
$policyScript = Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1'
Import-Module $modulePath -Force
$tokenMode = $PSCmdlet.ParameterSetName
$resolvedAccessTokenProviderPath = if ($tokenMode -eq 'TokenProvider') {
    (Resolve-Path $AccessTokenProviderPath).Path
}
else {
    $null
}

function Get-PlanAccessToken {
    param([Parameter(Mandatory)][string]$TargetDatabase)

    if ($tokenMode -eq 'StaticToken') {
        return $AccessToken
    }
    $providerOutput = @(
        & $resolvedAccessTokenProviderPath -DatabaseName $TargetDatabase
    )
    if (
        $providerOutput.Count -ne 1 -or
        $providerOutput[0] -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$providerOutput[0])
    ) {
        throw "The access token provider did not return exactly one token for '$TargetDatabase'."
    }
    return [string]$providerOutput[0]
}

function Invoke-SqlPackageAction {
    param(
        [Parameter(Mandatory)]
        [string]$Action,
        [Parameter(Mandatory)]
        [string]$TargetDatabase,
        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $connection = "Server=tcp:$ServerName,$Port;Initial Catalog=$TargetDatabase;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    $actionAccessToken = Get-PlanAccessToken -TargetDatabase $TargetDatabase
    $arguments = @(
        "/Action:$Action",
        "/SourceFile:$DacpacPath",
        "/TargetConnectionString:$connection",
        "/AccessToken:$actionAccessToken",
        "/OutputPath:$OutputPath",
        "/Profile:$PublishProfilePath",
        "/p:CommandTimeout=$CommandTimeout"
    )
    & $SqlPackagePath @arguments 2>&1 | ForEach-Object { Write-Host "[$TargetDatabase] $_" }
    if ($LASTEXITCODE -ne 0) {
        throw "$Action generation failed for '$TargetDatabase' with exit code $LASTEXITCODE."
    }
}

$targets = @(
    Resolve-DatabaseNames `
        -DatabaseNames $DatabaseNames `
        -DatabaseName $DatabaseName
)
$representative = $targets[0]
New-Item -ItemType Directory -Force -Path $ReviewPath | Out-Null

$scriptPath = Join-Path $ReviewPath 'deploy.sql'
$approvedReportPath = Join-Path $ReviewPath 'deploy-report.xml'
$policyReportPath = Join-Path $ReviewPath 'deployment-script-policy.md'
$targetMetadataPath = Join-Path $ReviewPath 'target-databases.json'
$allReportsPath = Join-Path $ReviewPath 'all-database-reports'
$allScriptsPath = Join-Path $ReviewPath 'all-database-scripts'
$allPolicyReportsPath = Join-Path $ReviewPath 'all-database-policy-reports'
foreach ($generatedFile in @(
    $scriptPath,
    $approvedReportPath,
    $policyReportPath,
    $targetMetadataPath,
    (Join-Path $ReviewPath 'ai-review.json'),
    (Join-Path $ReviewPath 'ai-review.md')
)) {
    Remove-Item -Path $generatedFile -Force -ErrorAction SilentlyContinue
}
foreach ($generatedDirectory in @(
    $allReportsPath,
    $allScriptsPath,
    $allPolicyReportsPath
)) {
    Remove-Item -Path $generatedDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-SqlPackageAction `
    -Action DeployReport `
    -TargetDatabase $representative `
    -OutputPath $approvedReportPath
Invoke-SqlPackageAction -Action Script -TargetDatabase $representative -OutputPath $scriptPath
& $policyScript `
    -ScriptPath $scriptPath `
    -ReportPath $policyReportPath

$drifted = [System.Collections.Generic.List[string]]::new()
if ($ValidateAllDatabasePlans) {
    New-Item -ItemType Directory -Force -Path $allReportsPath | Out-Null
    New-Item -ItemType Directory -Force -Path $allScriptsPath | Out-Null
    New-Item -ItemType Directory -Force -Path $allPolicyReportsPath | Out-Null
    Copy-Item `
        -Path $approvedReportPath `
        -Destination (Join-Path $allReportsPath "$representative.deploy-report.xml")
    Copy-Item `
        -Path $scriptPath `
        -Destination (Join-Path $allScriptsPath "$representative.deploy.sql")
    Copy-Item `
        -Path $policyReportPath `
        -Destination (Join-Path $allPolicyReportsPath "$representative.deployment-script-policy.md")

    foreach ($database in @($targets | Select-Object -Skip 1)) {
        $reportPath = Join-Path $allReportsPath "$database.deploy-report.xml"
        $databaseScriptPath = Join-Path $allScriptsPath "$database.deploy.sql"
        $databasePolicyReportPath = Join-Path $allPolicyReportsPath "$database.deployment-script-policy.md"
        Invoke-SqlPackageAction `
            -Action DeployReport `
            -TargetDatabase $database `
            -OutputPath $reportPath
        Invoke-SqlPackageAction `
            -Action Script `
            -TargetDatabase $database `
            -OutputPath $databaseScriptPath
        & $policyScript `
            -ScriptPath $databaseScriptPath `
            -ReportPath $databasePolicyReportPath
        try {
            & $confirmScript `
                -ApprovedReportPath $approvedReportPath `
                -CurrentReportPath $reportPath `
                -CompareOperationsOnly
        }
        catch {
            if ($_.Exception.Message -ne 'The target database changed after approval. Generate and approve a new deployment plan.') {
                throw
            }
            $drifted.Add($database)
            $message = "Database '$database' has a deployment plan that differs from representative '$representative'."
            if ($DatabasePlanDriftPolicy -eq 'Warn') {
                Write-Host "##vso[task.logissue type=warning]$message"
            }
            else {
                Write-Host "##vso[task.logissue type=error]$message"
            }
        }
    }
}
else {
    Write-Host '##vso[task.logissue type=warning]Only the representative database plan was generated. Enabling all-database plan validation adds one DeployReport and one gated Script operation per target and increases SQL MI load and pipeline cost.'
}

if ($DatabasePlanDriftPolicy -eq 'Fail' -and $drifted.Count -gt 0) {
    throw "All-database plan validation failed for: $($drifted -join ', ')"
}

$targetMetadata = [ordered]@{
    manifestVersion = 2
    environment = $EnvironmentName
    representativeDatabase = $representative
    targetDatabases = $targets
    allDatabasePlansValidated = [bool]$ValidateAllDatabasePlans
    allDatabaseScriptsGated = [bool]$ValidateAllDatabasePlans
    gatedDatabases = if ($ValidateAllDatabasePlans) { $targets } else { @($representative) }
    driftPolicy = $DatabasePlanDriftPolicy
}
$targetMetadata |
    ConvertTo-Json -Depth 4 |
    Set-Content -Path $targetMetadataPath -Encoding utf8

$summary = @(
    "## Database plan summary: $EnvironmentName",
    '',
    "- Representative database: $representative",
    "- Target database count: $($targets.Count)",
    "- All-database plan validation: $([bool]$ValidateAllDatabasePlans)",
    "- Drift policy: $DatabasePlanDriftPolicy",
    "- Different plans: $(if ($drifted.Count -eq 0) { 'none' } else { $drifted -join ', ' })"
)
if ($SummaryPath) {
    Add-Content -Path $SummaryPath -Value $summary -Encoding utf8
}

Write-Host "Representative deployment plan created for '$representative'."
