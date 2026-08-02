[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fixtures = Join-Path $repoRoot 'tests/fixtures'
$temporaryPath = Join-Path ([IO.Path]::GetTempPath()) "sqlmi-slim-tests-$PID"
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
New-Item -ItemType Directory -Force -Path $temporaryPath | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Policy {
    param([string]$Fixture)
    $report = Join-Path $temporaryPath "$Fixture.md"
    $output = @(
        & $pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
            -ScriptPath (Join-Path $fixtures $Fixture) `
            -ReportPath $report 2>&1
    )
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output -join [Environment]::NewLine
        Report = if (Test-Path $report) { Get-Content $report -Raw } else { '' }
    }
}

try {
    $safe = Invoke-Policy 'deployment-safe.sql'
    Assert-True ($safe.ExitCode -eq 0) 'Safe deployment fixture should pass.'

    $destructive = Invoke-Policy 'deployment-destructive.sql'
    Assert-True ($destructive.ExitCode -ne 0) 'Destructive deployment fixture should fail.'
    Assert-True ($destructive.Report -match 'DEPLOY001') 'Destructive report should contain DEPLOY001.'

    $rebuild = Invoke-Policy 'deployment-index-rebuild.sql'
    Assert-True ($rebuild.ExitCode -eq 0) 'Index rebuild fixture should be warning-only.'
    Assert-True ($rebuild.Report -match '\| warning \| DEPLOY003 \|') 'Index rebuild report should contain a DEPLOY003 warning.'
    Assert-True ($rebuild.Report -match '- Errors: 0') 'Index rebuild report should have no errors.'

    $pipeline = Get-Content (Join-Path $repoRoot 'azure-pipelines.yml') -Raw
    $deployTemplate = Get-Content (Join-Path $repoRoot 'pipelines/templates/deploy-stage.yml') -Raw
    Assert-True ($pipeline -match '\./eng/Test-Phase2\.ps1') 'Build stage must run slim self-tests.'
    Assert-True ($pipeline -match 'sqlServerModuleVersion:\s*22\.4\.5\.1') 'Pipeline must own the SqlServer module version.'
    Assert-True ($deployTemplate -match 'SQLSERVER_MODULE_VERSION') 'Deploy jobs must receive the SqlServer module version through the environment.'
    Assert-True ($deployTemplate -match 'deployment-review-\$\{\{\s*parameters\.environmentName\s*\}\}-pitr-marker-\$\(System\.JobAttempt\)') 'PITR artifact must include System.JobAttempt.'

    $deploy = Get-Content (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') -Raw
    Assert-True (@([regex]::Matches($deploy, '& \$AccessTokenProviderPath')).Count -eq 1) 'Database rollout must acquire one token before fan-out.'
    Assert-True ($deploy -notmatch '& \$WorkerContext\.AccessTokenProviderPath') 'Workers must not invoke the token provider.'
    Assert-True ($deploy -match "\[string\]\`$DeploymentMode = 'Publish'") 'Publish must be the script default.'
    Assert-True ($deploy -match "ValidateSet\('Publish', 'ValidatedScript'\)") 'ValidatedScript must remain an explicit mode.'
    Assert-True ($pipeline -match 'name:\s*deploymentMode[\s\S]*?default:\s*Publish') 'Pipeline deploymentMode must default to Publish.'
    Assert-True ($deployTemplate -match '-DeploymentMode\s+"\$\{\{\s*parameters\.deploymentMode\s*\}\}"') 'Deploy stage must pass deploymentMode.'

    $engFiles = Get-ChildItem $PSScriptRoot -Recurse -File
    $engBytes = ($engFiles | Measure-Object Length -Sum).Sum
    Assert-True ($engBytes -le 120000) "eng size exceeds 120000 bytes: $engBytes"
    foreach ($script in $engFiles | Where-Object Extension -in @('.ps1', '.psm1')) {
        Assert-True ((Get-Content $script.FullName).Count -le 500) "$($script.Name) exceeds 500 lines."
    }
    $sqlCmdModule = Get-Content (Join-Path $PSScriptRoot 'SqlCmd.Common.psm1') -Raw
    foreach ($removed in @(
        'Get-SqlLexicalState',
        'ConvertTo-SqlLexicalView',
        'ConvertTo-SqlToken',
        'Get-SqlStatement',
        'Read-SqlIdentifierPath',
        'Test-SqlInstanceStatementSequence',
        'Test-SqlInstanceGuardCoverage'
    )) {
        if ($removed -eq 'Test-SqlInstanceGuardCoverage') { continue }
        Assert-True ($sqlCmdModule -notmatch "function\s+$removed\b") "Removed parser helper remains: $removed"
    }

    Write-Host 'All education-slim Phase 2 self-tests passed.'
}
finally {
    if (Test-Path $temporaryPath) {
        Remove-Item $temporaryPath -Recurse -Force
    }
}
