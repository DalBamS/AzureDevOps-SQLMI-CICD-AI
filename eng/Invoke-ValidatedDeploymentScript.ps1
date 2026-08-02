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
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedSanitizedSha256,
    [ValidateRange(1, 2147483647)]
    [int]$CommandTimeout = 3600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sqlCmdModulePath = Join-Path $PSScriptRoot 'SqlCmd.Common.psm1'
Import-Module $sqlCmdModulePath -Force
$sqlCmdResolution = Resolve-SqlCmdScript -Path $ScriptPath
if (
    $sqlCmdResolution.SanitizedSha256 -cne
        $ExpectedSanitizedSha256.ToUpperInvariant()
) {
    throw 'The sanitized deployment script changed after the policy gate.'
}

$requiredVersion = $env:SQLSERVER_MODULE_VERSION
if ([string]::IsNullOrWhiteSpace($requiredVersion)) {
    throw 'SQLSERVER_MODULE_VERSION must identify the pipeline-pinned SqlServer module.'
}
$installedModule = Get-Module -ListAvailable -Name SqlServer |
    Where-Object Version -eq $requiredVersion |
    Select-Object -First 1
if (-not $installedModule) {
    throw "The pinned SqlServer PowerShell module $requiredVersion is required to execute deployment scripts."
}
Import-Module SqlServer -RequiredVersion $requiredVersion -Force

$serverInstance = "tcp:$ServerName,$Port"
Write-Information "Executing validated deployment script for '$DatabaseName'." -InformationAction Continue
$invokeArguments = @{
    ServerInstance = $serverInstance
    Database = $DatabaseName
    AccessToken = $AccessToken
    Query = $sqlCmdResolution.SanitizedText
    AbortOnError = $true
    DisableCommands = $true
    DisableVariables = $true
    Encrypt = 'Mandatory'
    TrustServerCertificate = $false
    ConnectionTimeout = 30
    QueryTimeout = $CommandTimeout
    ErrorAction = 'Stop'
}
Invoke-Sqlcmd @invokeArguments
