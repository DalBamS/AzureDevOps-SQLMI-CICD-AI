[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$DacVersion = '1.0.0.0',
    [ValidateSet('Lenient', 'Balanced', 'Strict')]
    [string]$Strictness = 'Strict',
    [AllowEmptyString()]
    [ValidatePattern('^$|^\d+(,\d+)*$')]
    [string]$ValidatedSuppressTSqlWarnings = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$project = [IO.Path]::Combine($repoRoot, 'database', 'App.Database', 'App.Database.sqlproj')
$output = [IO.Path]::Combine($repoRoot, 'artifacts', 'dacpac')

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'The .NET 10 SDK is required. Install it from https://dotnet.microsoft.com/download/dotnet/10.0.'
}
if ($Strictness -ne 'Balanced' -and $ValidatedSuppressTSqlWarnings) {
    throw 'ValidatedSuppressTSqlWarnings can be supplied only when Strictness is Balanced.'
}

$sdkList = & dotnet --list-sdks
if (-not $sdkList) {
    throw 'The dotnet host exists, but no SDK is installed. Install the .NET 10 SDK.'
}

New-Item -ItemType Directory -Force -Path $output | Out-Null

& dotnet build $project `
    --configuration $Configuration `
    --output $output `
    --nologo `
    "-p:DacVersion=$DacVersion" `
    "-p:BuildStrictness=$Strictness" `
    "-p:ValidatedSuppressTSqlWarnings=$ValidatedSuppressTSqlWarnings"

if ($LASTEXITCODE -ne 0) {
    throw "Database project build failed with exit code $LASTEXITCODE."
}

$dacpac = Join-Path $output 'App.Database.dacpac'
if (-not (Test-Path $dacpac)) {
    throw "Build completed without the expected DACPAC: $dacpac"
}

Write-Host "DACPAC created with $Strictness strictness: $dacpac"
