[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$ServerName,
    [ValidateRange(1, 65535)]
    [int]$Port = 1433,
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$DatabaseName,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AccessToken,
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ScriptPath,
    [ValidateRange(1, 2147483647)]
    [int]$CommandTimeout = 3600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredVersion = '22.4.5.1'
$installedModule = Get-Module -ListAvailable -Name SqlServer |
    Where-Object Version -eq $requiredVersion |
    Select-Object -First 1
if (-not $installedModule) {
    throw "The pinned SqlServer PowerShell module $requiredVersion is required to execute deployment scripts."
}
Import-Module SqlServer -RequiredVersion $requiredVersion -Force

$serverInstance = "tcp:$ServerName,$Port"
Write-Information "Executing validated deployment script for '$DatabaseName'." -InformationAction Continue
Invoke-Sqlcmd `
    -ServerInstance $serverInstance `
    -Database $DatabaseName `
    -AccessToken $AccessToken `
    -InputFile (Resolve-Path $ScriptPath).Path `
    -AbortOnError `
    -Encrypt Mandatory `
    -TrustServerCertificate:$false `
    -ConnectionTimeout 30 `
    -QueryTimeout $CommandTimeout `
    -ErrorAction Stop
