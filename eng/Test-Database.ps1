[CmdletBinding()]
param(
    [int]$HostPort = 14333,
    [switch]$SkipBuild,
    [switch]$KeepContainer,
    [ValidateRange(1, 2147483647)][int]$SqlCommandTimeout = 3600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dacpac = Join-Path $repoRoot 'artifacts/dacpac/App.Database.dacpac'
$profile = Join-Path $repoRoot 'pipelines/profiles/sqlmi-dev.publish.xml'
$toolDirectory = Join-Path ([IO.Path]::GetTempPath()) 'sqlpackage-170.4.83'
$sqlPackage = Join-Path $toolDirectory $(if ($IsWindows) { 'sqlpackage.exe' } else { 'sqlpackage' })
$containerId = $null
$password = "Local!Sql1_$([guid]::NewGuid().ToString('N').Substring(0, 12))"

foreach ($command in @('dotnet', 'docker')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required for the database integration test."
    }
}
if (-not $SkipBuild) { & (Join-Path $PSScriptRoot 'Build.ps1') }
if (-not (Test-Path $dacpac -PathType Leaf)) { throw "DACPAC not found: $dacpac" }
if (-not (Test-Path $sqlPackage -PathType Leaf)) {
    New-Item -ItemType Directory -Force $toolDirectory | Out-Null
    & dotnet tool install `
        --tool-path $toolDirectory `
        Microsoft.SqlPackage `
        --version 170.4.83 `
        --allow-roll-forward
    if ($LASTEXITCODE -ne 0) { throw 'SqlPackage installation failed.' }
}

try {
    $containerId = (& docker run `
        --detach `
        --rm `
        --env 'ACCEPT_EULA=Y' `
        --env "MSSQL_SA_PASSWORD=$password" `
        --publish "${HostPort}:1433" `
        mcr.microsoft.com/mssql/server:2025-latest).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $containerId) {
        throw 'SQL Server test container failed to start.'
    }
    $sqlcmd = (& docker exec $containerId sh -c `
        'for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do [ -x "$p" ] && echo "$p" && exit; done').Trim()
    $ready = $false
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        & docker exec $containerId $sqlcmd -S localhost -U sa -P $password -C -Q 'SELECT 1' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep 2
    }
    if (-not $ready) { throw 'SQL Server did not become ready within 120 seconds.' }

    & docker exec $containerId $sqlcmd -S localhost -U sa -P $password -C `
        -Q "CREATE DATABASE [AppDb_Test];" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Test database creation failed.' }
    $connection = "Server=localhost,$HostPort;Initial Catalog=AppDb_Test;User ID=sa;******;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
    & $sqlPackage `
        /Action:Publish `
        "/SourceFile:$dacpac" `
        "/TargetConnectionString:$connection" `
        "/Profile:$profile" `
        "/p:CommandTimeout=$SqlCommandTimeout"
    if ($LASTEXITCODE -ne 0) { throw 'DACPAC publish failed.' }

    $tests = Get-ChildItem (Join-Path $repoRoot 'tests/integration') -File -Filter '*.sql' |
        Sort-Object Name
    foreach ($test in $tests) {
        Write-Host "Running $($test.Name)"
        Get-Content $test.FullName -Raw |
            & docker exec --interactive $containerId $sqlcmd `
                -S localhost -U sa -P $password -C -b -d AppDb_Test
        if ($LASTEXITCODE -ne 0) { throw "Integration test failed: $($test.Name)" }
    }
    Write-Host "All $($tests.Count) database integration tests passed."
}
finally {
    if ($containerId -and -not $KeepContainer) {
        & docker rm --force $containerId | Out-Null
    }
}
