[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$generatedPaths = @(
    [IO.Path]::Combine($repoRoot, 'artifacts'),
    [IO.Path]::Combine($repoRoot, 'TestResults'),
    [IO.Path]::Combine($repoRoot, 'database', 'App.Database', 'bin'),
    [IO.Path]::Combine($repoRoot, 'database', 'App.Database', 'obj')
)

foreach ($path in $generatedPaths) {
    if (-not (Test-Path $path)) {
        continue
    }
    if ($PSCmdlet.ShouldProcess($path, 'Remove generated test and build output')) {
        Remove-Item -LiteralPath $path -Recurse -Force
        Write-Host "Removed generated path: $path"
    }
}

Write-Host 'Generated artifact cleanup completed.'
