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
    [ValidateNotNullOrEmpty()]
    [string]$AccessToken,
    [Parameter(Mandatory)]
    [string]$ReportPath,
    [ValidateRange(1, 2147483647)]
    [int]$CommandTimeout = 3600,
    [Parameter(Mandatory)]
    [string]$SummaryPath,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Phase2.Common.psm1') -Force

$targets = @(
    Resolve-DatabaseNames `
        -DatabaseNames $DatabaseNames `
        -DatabaseName $DatabaseName
)
$representative = $targets[0]
$reportDirectory = Split-Path -Parent $ReportPath
if ($reportDirectory) {
    New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
}
$summaryDirectory = Split-Path -Parent $SummaryPath
if ($summaryDirectory) {
    New-Item -ItemType Directory -Force -Path $summaryDirectory | Out-Null
}

$connection = "Server=tcp:$ServerName,$Port;Initial Catalog=$representative;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
$arguments = @(
    '/Action:DeployReport',
    "/SourceFile:$DacpacPath",
    "/TargetConnectionString:$connection",
    "/AccessToken:$AccessToken",
    "/OutputPath:$ReportPath",
    "/Profile:$PublishProfilePath",
    "/p:CommandTimeout=$CommandTimeout"
)
& $SqlPackagePath @arguments 2>&1 | ForEach-Object { Write-Host "[$representative] $_" }
if ($LASTEXITCODE -ne 0) {
    throw "DeployReport generation failed for '$representative' with exit code $LASTEXITCODE."
}
if (-not (Test-Path $ReportPath -PathType Leaf)) {
    throw "DeployReport generation did not create the expected report: $ReportPath"
}

$hasDrift = Test-DeployReportHasChanges -Path $ReportPath
$summary = @(
    "## Scheduled drift report: $EnvironmentName",
    '',
    "- Checked at UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
    "- Representative database: $representative",
    "- Configured database count: $($targets.Count)",
    '- Scope: representative database only (first resolved database)',
    "- Drift detected: $hasDrift"
)
Set-Content -Path $SummaryPath -Value $summary -Encoding utf8
Write-Host "##vso[task.uploadsummary]$SummaryPath"
Write-Host "##vso[task.setvariable variable=driftDetected]$($hasDrift.ToString().ToLowerInvariant())"

if ($hasDrift) {
    $message = "Schema drift detected in representative database '$representative'."
    Write-Host "##vso[task.logissue type=warning]$message"
    Write-Host "##vso[task.complete result=SucceededWithIssues;]$message"
}
else {
    Write-Host "No schema drift detected in representative database '$representative'."
}
