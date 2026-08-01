[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$ServerName,
    [ValidateRange(1, 65535)]
    [int]$Port = 1433,
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_]+$')]
    [string]$DatabaseName,
    [Parameter(Mandatory)]
    [string]$AccessToken,
    [string]$TestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $TestPath) {
    $TestPath = [IO.Path]::Combine($repoRoot, 'tests', 'integration')
}
if (-not (Test-Path $TestPath -PathType Container)) {
    throw "Integration test directory not found: $TestPath"
}
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    throw 'The pinned SqlServer PowerShell module is required to test the deployed database.'
}

$tests = @(
    Get-ChildItem -Path $TestPath -File -Filter '*.sql' |
        Sort-Object Name
)
if ($tests.Count -eq 0) {
    throw "No SQL integration tests found in: $TestPath"
}

$secureToken = ConvertTo-SecureString $AccessToken -AsPlainText -Force
$serverInstance = "tcp:$ServerName,$Port"

foreach ($test in $tests) {
    Write-Host "Running $($test.Name) against $DatabaseName"
    Invoke-Sqlcmd `
        -ServerInstance $serverInstance `
        -Database $DatabaseName `
        -AccessToken $secureToken `
        -InputFile $test.FullName `
        -AbortOnError `
        -Encrypt Mandatory `
        -TrustServerCertificate:$false `
        -ErrorAction Stop
}

Write-Host "All $($tests.Count) SQL MI integration tests passed for $DatabaseName."
