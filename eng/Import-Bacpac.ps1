[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ServerName,
    [Parameter(Mandatory)]
    [string]$DatabaseName,
    [Parameter(Mandatory)]
    [string]$BacpacPath,
    [ValidateRange(1, 65535)]
    [int]$Port = 1433,
    [string]$SqlPackagePath = 'sqlpackage'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $BacpacPath)) {
    throw "BACPAC not found: $BacpacPath"
}
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

$connectionString = "Server=tcp:$ServerName,$Port;Initial Catalog=$DatabaseName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

& $SqlPackagePath `
    /Action:Import `
    "/SourceFile:$([IO.Path]::GetFullPath($BacpacPath))" `
    "/TargetConnectionString:$connectionString" `
    "/AccessToken:$token"

if ($LASTEXITCODE -ne 0) {
    throw "BACPAC import failed with exit code $LASTEXITCODE."
}

Write-Host "BACPAC imported into $ServerName/$DatabaseName."
