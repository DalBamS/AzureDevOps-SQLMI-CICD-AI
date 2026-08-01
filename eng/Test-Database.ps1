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
$toolDirectory = [IO.Path]::Combine($artifacts, 'tools', 'sqlpackage')
$publishProfile = [IO.Path]::Combine($repoRoot, 'pipelines', 'profiles', 'sqlmi-dev.publish.xml')
$sqlPackageVersion = '170.4.83'
$containerId = $null
$sqlcmdPath = $null

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
    & $sqlPackage `
        /Action:Publish `
        "/SourceFile:$dacpac" `
        "/TargetConnectionString:$connectionString" `
        "/Profile:$publishProfile" `
        "/p:CommandTimeout=$SqlCommandTimeout"
    if ($LASTEXITCODE -ne 0) {
        throw 'DACPAC deployment to the integration test database failed.'
    }

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
}
