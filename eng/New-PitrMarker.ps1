[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$DatabaseName,
    [AllowEmptyString()]
    [string]$DatabaseNames,
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$ServerName,
    [Parameter(Mandatory)]
    [string]$EnvironmentName,
    [Parameter(Mandatory)]
    [string]$OutputPath,
    [AllowEmptyString()]
    [string]$BuildId,
    [AllowEmptyString()]
    [string]$SourceVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Phase2.Common.psm1') -Force
$targets = @(
    Resolve-DatabaseNames `
        -DatabaseNames $DatabaseNames `
        -DatabaseName $DatabaseName
)
$marker = [ordered]@{
    pitrReferenceUtc = [datetime]::UtcNow.ToString('o')
    environment = $EnvironmentName
    server = $ServerName
    databases = $targets
    buildId = $BuildId
    sourceVersion = $SourceVersion
    note = 'Reference time captured immediately before the deployment command; confirm Azure SQL MI backup retention before restore.'
}

$directory = Split-Path -Parent $OutputPath
if ($directory) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
$marker | ConvertTo-Json -Depth 4 | Set-Content -Path $OutputPath -Encoding utf8
Write-Host "PITR reference marker created: $OutputPath"
