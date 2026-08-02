# Optional education guard for readability and ownership, not a functional requirement.
[CmdletBinding()]
param(
    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaximumEngBytes = 120000,
    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaximumScriptLines = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$engFiles = Get-ChildItem $PSScriptRoot -Recurse -File
$engBytes = ($engFiles | Measure-Object Length -Sum).Sum
if ($engBytes -gt $MaximumEngBytes) {
    throw "eng size exceeds the optional education guard: $engBytes bytes."
}
foreach ($script in $engFiles | Where-Object Extension -in @('.ps1', '.psm1')) {
    $lineCount = (Get-Content $script.FullName).Count
    if ($lineCount -gt $MaximumScriptLines) {
        throw "$($script.Name) exceeds the optional education guard: $lineCount lines."
    }
}

$pipelinePath = Join-Path $repoRoot 'azure-pipelines.yml'
$pipeline = Get-Content $pipelinePath -Raw
$versionOwners = [regex]::Matches(
    $pipeline,
    '(?m)^\s*sqlServerModuleVersion:\s*(?<value>\S+)\s*$'
)
if ($versionOwners.Count -ne 1) {
    throw 'azure-pipelines.yml must own sqlServerModuleVersion exactly once.'
}
$ownedVersion = $versionOwners[0].Groups['value'].Value
$deployTemplate = Get-Content (Join-Path $repoRoot 'pipelines/templates/deploy-stage.yml') -Raw
if ($deployTemplate -notmatch 'SQLSERVER_MODULE_VERSION:\s*\$\(sqlServerModuleVersion\)') {
    throw 'Deploy jobs must receive sqlServerModuleVersion through SQLSERVER_MODULE_VERSION.'
}
foreach ($script in $engFiles | Where-Object Extension -in @('.ps1', '.psm1')) {
    if ((Get-Content $script.FullName -Raw) -match [regex]::Escape($ownedVersion)) {
        throw "$($script.Name) hardcodes the pipeline-owned SqlServer module version."
    }
}

Write-Host 'Optional repository readability and ownership constraints passed.'
