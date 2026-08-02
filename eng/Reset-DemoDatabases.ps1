[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$ServerName,
    [ValidateRange(1, 65535)]
    [int]$Port = 1433,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$DatabaseName,
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$DeployerPrincipalName,
    [Parameter(Mandatory)]
    [string]$AccessToken,
    [Parameter(Mandatory)]
    [switch]$ConfirmReset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfirmReset) {
    throw 'Pass -ConfirmReset to acknowledge permanent deletion of all data in the Demo databases.'
}
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    throw 'The pipeline-pinned SqlServer PowerShell module is required. Install it from PSGallery.'
}

foreach ($name in $DatabaseName) {
    if ($name -notmatch '^AppDb_CicdDemo_[A-Za-z0-9_]+$') {
        throw "Only AppDb_CicdDemo_* databases can be reset: $name"
    }
}

$targetDescription = "$ServerName/$($DatabaseName -join ',')"
if (-not $PSCmdlet.ShouldProcess(
    $targetDescription,
    'Permanently drop and recreate the Demo databases'
)) {
    return
}

$serverInstance = "tcp:$ServerName,$Port"
$initializer = Join-Path $PSScriptRoot 'Initialize-DemoDatabases.ps1'

foreach ($name in $DatabaseName) {
    $dropDatabase = @"
IF DB_ID(N'$name') IS NOT NULL
BEGIN
    EXEC(N'ALTER DATABASE [$name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE');
    EXEC(N'DROP DATABASE [$name]');
END;
"@
    Invoke-Sqlcmd `
        -ServerInstance $serverInstance `
        -Database master `
        -AccessToken $AccessToken `
        -Query $dropDatabase `
        -AbortOnError `
        -Encrypt Mandatory `
        -TrustServerCertificate:$false `
        -ErrorAction Stop

    & $initializer `
        -ServerName $ServerName `
        -Port $Port `
        -DatabaseName @($name) `
        -DeployerPrincipalName $DeployerPrincipalName `
        -AccessToken $AccessToken

    Write-Host "Demo database reset to empty state: $name"
}
