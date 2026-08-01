[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ServerName,
    [Parameter(Mandatory)]
    [string]$DatabaseName,
    [Parameter(Mandatory)]
    [string]$OutputPath,
    [ValidateRange(1, 65535)]
    [int]$Port = 1433,
    [string]$SqlPackagePath = 'sqlpackage'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($command in @('az', $SqlPackagePath)) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required."
    }
}

$token = (& az account get-access-token `
    --resource 'https://database.windows.net/' `
    --query accessToken `
    --output tsv).Trim()
if ($LASTEXITCODE -ne 0 -or -not $token) {
    throw 'Unable to acquire an Azure SQL access token. Run az login first.'
}

$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fullOutputPath) | Out-Null
$connectionString = "Server=tcp:$ServerName,$Port;Initial Catalog=$DatabaseName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

& $SqlPackagePath `
    /Action:Export `
    "/SourceConnectionString:$connectionString" `
    "/TargetFile:$fullOutputPath" `
    "/AccessToken:$token"

if ($LASTEXITCODE -ne 0) {
    throw "BACPAC export failed with exit code $LASTEXITCODE."
}

Write-Host "BACPAC exported: $fullOutputPath"
