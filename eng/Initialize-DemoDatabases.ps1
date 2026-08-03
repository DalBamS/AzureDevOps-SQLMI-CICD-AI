[CmdletBinding()]
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
    [string]$AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    throw 'The pipeline-pinned SqlServer PowerShell module is required. Install it from PSGallery.'
}

$serverInstance = "tcp:$ServerName,$Port"

foreach ($name in $DatabaseName) {
    if ($name -notmatch '^[A-Za-z0-9_]+$') {
        throw "Database name contains unsupported characters: $name"
    }

    $createDatabase = @"
IF DB_ID(N'$name') IS NULL
BEGIN
    EXEC(N'CREATE DATABASE [$name]');
END;
"@
    Invoke-Sqlcmd `
        -ServerInstance $serverInstance `
        -Database master `
        -AccessToken $AccessToken `
        -Query $createDatabase `
        -AbortOnError `
        -Encrypt Mandatory `
        -TrustServerCertificate:$false `
        -ErrorAction Stop

    $configureDeployer = @"
IF DATABASE_PRINCIPAL_ID(N'$DeployerPrincipalName') IS NULL
BEGIN
    CREATE USER [$DeployerPrincipalName] FROM EXTERNAL PROVIDER;
END;
IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_role_members AS drm
    INNER JOIN sys.database_principals AS role_principal
        ON role_principal.principal_id = drm.role_principal_id
    INNER JOIN sys.database_principals AS member_principal
        ON member_principal.principal_id = drm.member_principal_id
    WHERE role_principal.name = N'db_ddladmin'
      AND member_principal.name = N'$DeployerPrincipalName'
)
    ALTER ROLE [db_ddladmin] ADD MEMBER [$DeployerPrincipalName];
IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_role_members AS drm
    INNER JOIN sys.database_principals AS role_principal
        ON role_principal.principal_id = drm.role_principal_id
    INNER JOIN sys.database_principals AS member_principal
        ON member_principal.principal_id = drm.member_principal_id
    WHERE role_principal.name = N'db_datareader'
      AND member_principal.name = N'$DeployerPrincipalName'
)
    ALTER ROLE [db_datareader] ADD MEMBER [$DeployerPrincipalName];
IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_role_members AS drm
    INNER JOIN sys.database_principals AS role_principal
        ON role_principal.principal_id = drm.role_principal_id
    INNER JOIN sys.database_principals AS member_principal
        ON member_principal.principal_id = drm.member_principal_id
    WHERE role_principal.name = N'db_datawriter'
      AND member_principal.name = N'$DeployerPrincipalName'
)
    ALTER ROLE [db_datawriter] ADD MEMBER [$DeployerPrincipalName];
IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_role_members AS drm
    INNER JOIN sys.database_principals AS role_principal
        ON role_principal.principal_id = drm.role_principal_id
    INNER JOIN sys.database_principals AS member_principal
        ON member_principal.principal_id = drm.member_principal_id
    WHERE role_principal.name = N'db_owner'
      AND member_principal.name = N'$DeployerPrincipalName'
)
    ALTER ROLE [db_owner] ADD MEMBER [$DeployerPrincipalName];
GRANT VIEW DEFINITION TO [$DeployerPrincipalName];
"@
    Invoke-Sqlcmd `
        -ServerInstance $serverInstance `
        -Database $name `
        -AccessToken $AccessToken `
        -Query $configureDeployer `
        -AbortOnError `
        -Encrypt Mandatory `
        -TrustServerCertificate:$false `
        -ErrorAction Stop

    Write-Host "Demo database ready: $name"
}
