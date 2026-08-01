[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$DatabaseName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required to acquire an Azure SQL access token.'
}

Write-Verbose "Acquiring an Azure SQL access token for database '$DatabaseName'."
$token = (& az account get-access-token `
    --resource 'https://database.windows.net/' `
    --query accessToken `
    --output tsv `
    --only-show-errors).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw 'Unable to acquire an Azure SQL access token.'
}

$token
