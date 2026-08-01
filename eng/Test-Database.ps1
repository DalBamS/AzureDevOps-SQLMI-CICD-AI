[CmdletBinding()]
param(
    [int]$HostPort = 14333,
    [switch]$SkipBuild,
    [switch]$KeepContainer,
    [ValidateRange(1, 2147483647)]
    [int]$SqlCommandTimeout = 3600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$artifacts = Join-Path $repoRoot 'artifacts'
$dacpac = [IO.Path]::Combine($artifacts, 'dacpac', 'App.Database.dacpac')
$sqlPackageVersion = '170.4.83'
$toolCacheRoot = if ($env:AGENT_TEMPDIRECTORY) {
    $env:AGENT_TEMPDIRECTORY
}
else {
    [IO.Path]::GetTempPath()
}
$toolDirectory = Join-Path $toolCacheRoot "sqlpackage-$sqlPackageVersion"
$publishProfile = [IO.Path]::Combine($repoRoot, 'pipelines', 'profiles', 'sqlmi-dev.publish.xml')
$sqlServerModuleVersion = '22.4.5.1'
$containerId = $null
$sqlcmdPath = $null
$exactScriptTestPath = Join-Path ([IO.Path]::GetTempPath()) "sqlmi-exact-script-$PID"

if ($env:sqlCommandTimeout) {
    $parsedTimeout = 0
    if (-not [int]::TryParse($env:sqlCommandTimeout, [ref]$parsedTimeout) -or $parsedTimeout -lt 1) {
        throw 'Environment variable sqlCommandTimeout must be a positive integer.'
    }
    $SqlCommandTimeout = $parsedTimeout
}

foreach ($command in @('dotnet', 'docker')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required. See docs/환경-구성-및-테스트.md."
    }
}
$sqlServerModule = Get-Module -ListAvailable -Name SqlServer |
    Where-Object Version -eq $sqlServerModuleVersion |
    Select-Object -First 1
if (-not $sqlServerModule) {
    Install-Module `
        -Name SqlServer `
        -RequiredVersion $sqlServerModuleVersion `
        -Scope CurrentUser `
        -Repository PSGallery `
        -Force `
        -AllowClobber
}
Import-Module SqlServer -RequiredVersion $sqlServerModuleVersion -Force

if (-not $SkipBuild) {
    & ([IO.Path]::Combine($PSScriptRoot, 'Build.ps1'))
}
if (-not (Test-Path $dacpac)) {
    throw "DACPAC not found: $dacpac"
}

$sqlPackageName = if ($IsWindows) { 'sqlpackage.exe' } else { 'sqlpackage' }
$sqlPackage = Join-Path $toolDirectory $sqlPackageName
if (-not (Test-Path $sqlPackage)) {
    New-Item -ItemType Directory -Force -Path $toolDirectory | Out-Null
    & dotnet tool install `
        --tool-path $toolDirectory `
        Microsoft.SqlPackage `
        --version $sqlPackageVersion `
        --allow-roll-forward
    if ($LASTEXITCODE -ne 0) {
        throw 'SqlPackage installation failed.'
    }
}

$password = "Local!Sql1_$([guid]::NewGuid().ToString('N').Substring(0, 12))"
$containerName = "sqlmi-cicd-test-$PID"

try {
    $containerId = (& docker run `
        --detach `
        --rm `
        --name $containerName `
        --env 'ACCEPT_EULA=Y' `
        --env "MSSQL_SA_PASSWORD=$password" `
        --publish "${HostPort}:1433" `
        mcr.microsoft.com/mssql/server:2025-latest).Trim()

    if ($LASTEXITCODE -ne 0 -or -not $containerId) {
        throw 'SQL Server test container failed to start.'
    }

    $sqlcmdPath = (& docker exec $containerId sh -c `
        'for path in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do if [ -x "$path" ]; then echo "$path"; exit 0; fi; done; command -v sqlcmd').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $sqlcmdPath) {
        throw 'sqlcmd was not found inside the SQL Server container.'
    }

    $ready = $false
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        & docker exec $containerId `
            $sqlcmdPath `
            -S localhost -U sa -P $password -C -Q 'SELECT 1' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 2
    }

    if (-not $ready) {
        & docker logs $containerId
        throw 'SQL Server did not become ready within 120 seconds.'
    }

    & docker exec $containerId `
        $sqlcmdPath `
        -S localhost -U sa -P $password -C `
        -Q "IF DB_ID(N'AppDb_Test') IS NULL CREATE DATABASE [AppDb_Test];"
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the integration test database.'
    }

    $connectionString = "Server=localhost,$HostPort;Initial Catalog=AppDb_Test;User ID=sa;Password=$password;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
    New-Item -ItemType Directory -Force -Path $exactScriptTestPath | Out-Null
    $initialScriptPath = Join-Path $exactScriptTestPath 'initial.deploy.sql'
    $initialPolicyPath = Join-Path $exactScriptTestPath 'initial.policy.md'
    & $sqlPackage `
        /Action:Script `
        "/SourceFile:$dacpac" `
        "/TargetConnectionString:$connectionString" `
        "/OutputPath:$initialScriptPath" `
        "/Profile:$publishProfile" `
        "/p:CommandTimeout=$SqlCommandTimeout"
    if ($LASTEXITCODE -ne 0) {
        throw 'Initial exact deployment script generation failed.'
    }
    & ([IO.Path]::Combine($PSScriptRoot, 'Test-DeploymentScript.ps1')) `
        -ScriptPath $initialScriptPath `
        -ReportPath $initialPolicyPath
    Invoke-Sqlcmd `
        -ServerInstance "tcp:localhost,$HostPort" `
        -Database AppDb_Test `
        -Username sa `
        -Password $password `
        -InputFile $initialScriptPath `
        -AbortOnError `
        -Encrypt Mandatory `
        -TrustServerCertificate `
        -ConnectionTimeout 30 `
        -QueryTimeout $SqlCommandTimeout `
        -ErrorAction Stop

    $seedQueryArguments = @{
        ServerInstance = "tcp:localhost,$HostPort"
        Database = 'AppDb_Test'
        Username = 'sa'
        Password = $password
        Encrypt = 'Mandatory'
        TrustServerCertificate = $true
        ConnectionTimeout = 30
        QueryTimeout = $SqlCommandTimeout
        ErrorAction = 'Stop'
    }
    $initialSeedCount = (
        Invoke-Sqlcmd @seedQueryArguments -Query @'
SELECT COUNT_BIG(*) AS [SeedCount]
FROM [app].[FeatureFlag]
WHERE [FlagName] = N'database-cicd-ready';
'@
    ).SeedCount
    if ($initialSeedCount -ne 1) {
        throw 'The initial exact deployment script did not execute the post-deployment seed.'
    }

    $retryReportPath = Join-Path $exactScriptTestPath 'retry.deploy-report.xml'
    $retryScriptPath = Join-Path $exactScriptTestPath 'retry.deploy.sql'
    $retryPolicyPath = Join-Path $exactScriptTestPath 'retry.policy.md'
    & $sqlPackage `
        /Action:DeployReport `
        "/SourceFile:$dacpac" `
        "/TargetConnectionString:$connectionString" `
        "/OutputPath:$retryReportPath" `
        "/Profile:$publishProfile" `
        "/p:CommandTimeout=$SqlCommandTimeout"
    if ($LASTEXITCODE -ne 0) {
        throw 'Retry DeployReport generation failed.'
    }
    Import-Module ([IO.Path]::Combine($PSScriptRoot, 'Phase2.Common.psm1')) -Force
    if (Test-DeployReportHasChanges -Path $retryReportPath) {
        throw 'The retry DeployReport should contain no schema operations.'
    }
    Invoke-Sqlcmd @seedQueryArguments -Query @'
DELETE FROM [app].[FeatureFlag]
WHERE [FlagName] = N'database-cicd-ready';
'@
    & $sqlPackage `
        /Action:Script `
        "/SourceFile:$dacpac" `
        "/TargetConnectionString:$connectionString" `
        "/OutputPath:$retryScriptPath" `
        "/Profile:$publishProfile" `
        "/p:CommandTimeout=$SqlCommandTimeout"
    if ($LASTEXITCODE -ne 0) {
        throw 'Retry exact deployment script generation failed.'
    }
    & ([IO.Path]::Combine($PSScriptRoot, 'Test-DeploymentScript.ps1')) `
        -ScriptPath $retryScriptPath `
        -ReportPath $retryPolicyPath
    Invoke-Sqlcmd `
        -ServerInstance "tcp:localhost,$HostPort" `
        -Database AppDb_Test `
        -Username sa `
        -Password $password `
        -InputFile $retryScriptPath `
        -AbortOnError `
        -Encrypt Mandatory `
        -TrustServerCertificate `
        -ConnectionTimeout 30 `
        -QueryTimeout $SqlCommandTimeout `
        -ErrorAction Stop
    $retrySeedCount = (
        Invoke-Sqlcmd @seedQueryArguments -Query @'
SELECT COUNT_BIG(*) AS [SeedCount]
FROM [app].[FeatureFlag]
WHERE [FlagName] = N'database-cicd-ready';
'@
    ).SeedCount
    if ($retrySeedCount -ne 1) {
        throw 'The empty-report retry script did not restore post-deployment seed data.'
    }
    Write-Information `
        'SqlPackage exact-script execution and empty-report retry passed.' `
        -InformationAction Continue

    $tests = Get-ChildItem -Path ([IO.Path]::Combine($repoRoot, 'tests', 'integration')) -File -Filter '*.sql' |
        Sort-Object Name
    foreach ($test in $tests) {
        Write-Host "Running $($test.Name)"
        Get-Content -Path $test.FullName -Raw |
            & docker exec --interactive $containerId `
                $sqlcmdPath `
                -S localhost -U sa -P $password -C -b -d AppDb_Test
        if ($LASTEXITCODE -ne 0) {
            throw "Integration test failed: $($test.Name)"
        }
    }

    Write-Host "All $($tests.Count) database integration tests passed."
}
finally {
    if ($containerId -and -not $KeepContainer) {
        & docker rm --force $containerId | Out-Null
    }
    if (Test-Path $exactScriptTestPath) {
        Remove-Item -Path $exactScriptTestPath -Recurse -Force
    }
}
