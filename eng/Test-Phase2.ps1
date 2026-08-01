[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$modulePath = Join-Path $PSScriptRoot 'Phase2.Common.psm1'
$fixtures = [IO.Path]::Combine($repoRoot, 'tests', 'fixtures')
$temporaryPath = Join-Path ([IO.Path]::GetTempPath()) "sqlmi-phase2-tests-$PID"
New-Item -ItemType Directory -Force -Path $temporaryPath | Out-Null
Import-Module $modulePath -Force

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ("$Actual" -ne "$Expected") {
        throw "$Message Expected '$Expected', received '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
    }
    if (-not $threw) {
        throw $Message
    }
}

try {
    $fallback = @(
        Resolve-DatabaseNames `
            -DatabaseNames '$(databaseNames)' `
            -DatabaseName 'LegacyDb'
    )
    Assert-Equal $fallback.Count 1 'The legacy databaseName fallback should resolve one target.'
    Assert-Equal $fallback[0] 'LegacyDb' 'The legacy databaseName fallback selected the wrong target.'

    $multiple = @(
        Resolve-DatabaseNames `
            -DatabaseNames ' CanaryDb,Shard02,canarydb,Shard03 ' `
            -DatabaseName 'IgnoredDb'
    )
    Assert-Equal $multiple.Count 3 'Database list parsing should trim and de-duplicate names.'
    $rollout = Get-DatabaseRollout -DatabaseNames $multiple
    Assert-Equal $rollout.Canary 'CanaryDb' 'The first target must be selected as the canary.'
    Assert-Equal $rollout.Remaining.Count 2 'The remaining rollout list is incorrect.'
    Assert-Throws {
        Resolve-DatabaseNames -DatabaseNames 'ValidDb,,OtherDb' -DatabaseName ''
    } 'An empty databaseNames entry should fail validation.'

    Assert-True `
        -Condition (-not (Test-DeployReportHasChanges -Path (Join-Path $fixtures 'deploy-report-empty.xml'))) `
        -Message 'An empty DeployReport should be recognized as already current.'
    Assert-True `
        -Condition (Test-DeployReportHasChanges -Path (Join-Path $fixtures 'deploy-report-changed.xml')) `
        -Message 'A DeployReport operation should be recognized as a pending change.'
    & (Join-Path $PSScriptRoot 'Confirm-DeploymentPlan.ps1') `
        -ApprovedReportPath (Join-Path $fixtures 'deploy-report-changed.xml') `
        -CurrentReportPath (Join-Path $fixtures 'deploy-report-changed-shard.xml') `
        -CompareOperationsOnly
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Confirm-DeploymentPlan.ps1') `
            -ApprovedReportPath (Join-Path $fixtures 'deploy-report-changed.xml') `
            -CurrentReportPath (Join-Path $fixtures 'deploy-report-changed-shard.xml')
    } 'Full report comparison should preserve target-specific metadata checks.'

    $operation = {
        param($Database, $Context)

        Start-Sleep -Milliseconds $Context.Delay
        if ($Database -eq $Context.FailDatabase) {
            return [pscustomobject]@{
                DatabaseName = $Database
                Success = $false
                Status = 'Failed'
                Error = 'fixture failure'
            }
        }
        return [pscustomobject]@{
            DatabaseName = $Database
            Success = $true
            Status = 'fixture success'
            Error = ''
        }
    }
    $fanOutResults = @(
        Invoke-DatabaseFanOut `
            -DatabaseNames @('Shard01', 'Shard02', 'Shard03') `
            -Operation $operation `
            -Context ([pscustomobject]@{ Delay = 20; FailDatabase = 'Shard02' }) `
            -MaxParallel 2
    )
    Assert-Equal $fanOutResults.Count 3 'Parallel fan-out should collect every database result.'
    Assert-Equal @($fanOutResults | Where-Object { -not $_.Success }).Count 1 'Parallel fan-out should aggregate one failure.'
    Assert-Equal @($fanOutResults | Where-Object { -not $_.Success })[0].DatabaseName 'Shard02' 'Parallel fan-out reported the wrong failed database.'

    $instanceArguments = @{
        ServerName = 'sqlmi.example.test'
        AccessToken = 'fixture-token'
        ScriptPath = [IO.Path]::Combine($repoRoot, 'database', 'instance')
        SqlcmdVariables = @{
            EntraLoginName = 'example-deployer'
            AgentJobName = 'Example Health Job'
            AgentJobOwner = 'example-deployer'
        }
        WhatIf = $true
    }
    & (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') @instanceArguments
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') `
            -ServerName 'sqlmi.example.test' `
            -AccessToken 'fixture-token' `
            -ScriptPath ([IO.Path]::Combine($repoRoot, 'database', 'instance')) `
            -SqlcmdVariables @{
                EntraLoginName = 'example-deployer'
                AgentJobName = 'Example Health Job'
            } `
            -WhatIf
    } 'Missing instance SQLCMD variables should fail validation, including under WhatIf.'

    & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
        -ScriptPath (Join-Path $fixtures 'deployment-safe.sql') `
        -ReportPath (Join-Path $temporaryPath 'safe-report.md')
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
            -ScriptPath (Join-Path $fixtures 'deployment-destructive.sql') `
            -ReportPath (Join-Path $temporaryPath 'destructive-report.md')
    } 'The Phase 1 destructive deployment regression fixture should fail.'

    $parseFailures = [System.Collections.Generic.List[string]]::new()
    $powerShellFiles = @(
        Get-ChildItem -Path $PSScriptRoot -File |
            Where-Object Extension -in @('.ps1', '.psm1')
    )
    foreach ($file in $powerShellFiles) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$errors
        )
        foreach ($parseError in $errors) {
            $parseFailures.Add("$($file.Name): $($parseError.Message)")
        }
    }
    Assert-Equal $parseFailures.Count 0 "PowerShell parser failures: $($parseFailures -join '; ')"

    $pipelinePath = Join-Path $repoRoot 'azure-pipelines.yml'
    $templatePath = [IO.Path]::Combine($repoRoot, 'pipelines', 'templates', 'deploy-stage.yml')
    $pipelineText = Get-Content -Path $pipelinePath -Raw
    $templateText = Get-Content -Path $templatePath -Raw
    Assert-True `
        -Condition ($templateText -notmatch '\$\{\{\s*each[^\r\n]*databaseNames') `
        -Message 'Runtime databaseNames must not be expanded by a compile-time each expression.'
    Assert-True `
        -Condition ($templateText -match 'DeployInstanceObjects[\s\S]+dependsOn:\s*DeployDacpac') `
        -Message 'Instance object deployment must depend on successful DACPAC rollout.'
    Assert-True `
        -Condition ($templateText -match 'deployment-review-\$\{\{\s*parameters\.environmentName\s*\}\}-pitr-marker') `
        -Message 'The deployment review PITR marker artifact is missing.'
    Assert-True `
        -Condition ($pipelineText -match '(?m)^\s*default:\s*4\s*$') `
        -Message 'The maxParallel default of 4 is missing.'
    Assert-True `
        -Condition ($pipelineText -notmatch '-ValidatedSuppressTSqlWarnings\s+"\$\{\{\s*parameters\.validatedSuppressTSqlWarnings\s*\}\}"') `
        -Message 'Queue-supplied warning values must not be interpolated into PowerShell source.'
    Assert-True `
        -Condition (
            $pipelineText -match '-ValidatedSuppressTSqlWarnings\s+\$env:VALIDATED_SUPPRESS_TSQL_WARNINGS' -and
            $pipelineText -match 'VALIDATED_SUPPRESS_TSQL_WARNINGS:\s*\$\{\{\s*parameters\.validatedSuppressTSqlWarnings\s*\}\}'
        ) `
        -Message 'Queue-supplied warning values must cross the pipeline boundary through an environment variable.'

    $injectionMarker = Join-Path $temporaryPath 'pipeline-parameter-injection.txt'
    $env:PHASE2_WARNING_PAYLOAD = "46010`"; Set-Content -Path '$injectionMarker' -Value injected; #"
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Build.ps1') `
            -Strictness Balanced `
            -ValidatedSuppressTSqlWarnings $env:PHASE2_WARNING_PAYLOAD
    } 'An injection-shaped warning value must be rejected as data.'
    Assert-True `
        -Condition (-not (Test-Path $injectionMarker)) `
        -Message 'The injection-shaped warning value was executed as PowerShell source.'

    $fakeDacpac = Join-Path $temporaryPath 'fixture.dacpac'
    $fakeProfile = Join-Path $temporaryPath 'fixture.publish.xml'
    Set-Content -Path $fakeDacpac -Value 'fixture' -Encoding utf8
    Set-Content -Path $fakeProfile -Value '<Project />' -Encoding utf8

    $planLog = Join-Path $temporaryPath 'plan-actions.log'
    $fakeSqlPackage = Join-Path $temporaryPath 'fake-sqlpackage.ps1'
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

$action = ($Arguments | Where-Object { $_ -like '/Action:*' }) -replace '^/Action:', ''
$outputPath = ($Arguments | Where-Object { $_ -like '/OutputPath:*' }) -replace '^/OutputPath:', ''
Add-Content -Path $env:PHASE2_PLAN_LOG -Value $action -Encoding utf8
if ($action -eq 'DeployReport') {
    Copy-Item -Path $env:PHASE2_CHANGED_REPORT -Destination $outputPath -Force
}
elseif ($action -eq 'Script') {
    Set-Content -Path $outputPath -Value 'SELECT 1;' -Encoding utf8
}
$global:LASTEXITCODE = 0
'@ | Set-Content -Path $fakeSqlPackage -Encoding utf8

    $reviewPath = Join-Path $temporaryPath 'deployment-review'
    $allReportsPath = Join-Path $reviewPath 'all-database-reports'
    New-Item -ItemType Directory -Force -Path $allReportsPath | Out-Null
    Set-Content -Path (Join-Path $reviewPath 'deploy.sql') -Value 'stale script' -Encoding utf8
    Set-Content -Path (Join-Path $allReportsPath 'Shard02.deploy-report.xml') -Value '<stale />' -Encoding utf8
    $env:PHASE2_PLAN_LOG = $planLog
    $env:PHASE2_CHANGED_REPORT = Join-Path $fixtures 'deploy-report-changed.xml'
    & (Join-Path $PSScriptRoot 'New-DatabaseDeploymentPlan.ps1') `
        -ServerName 'sqlmi.example.test' `
        -DatabaseNames 'CanaryDb,Shard02' `
        -DacpacPath $fakeDacpac `
        -PublishProfilePath $fakeProfile `
        -SqlPackagePath $fakeSqlPackage `
        -AccessToken 'fixture-token' `
        -ReviewPath $reviewPath
    $planActions = @(Get-Content -Path $planLog)
    Assert-Equal $planActions[0] 'DeployReport' 'The approved DeployReport must be captured before the gated deployment script.'
    Assert-Equal $planActions[1] 'Script' 'The deployment script must be generated and gated after the approved DeployReport.'
    Assert-True `
        -Condition (-not (Test-Path $allReportsPath)) `
        -Message 'A run with all-database validation disabled must remove stale per-database reports.'

    $tokenLogDirectory = Join-Path $temporaryPath 'token-refresh'
    New-Item -ItemType Directory -Force -Path $tokenLogDirectory | Out-Null
    $fakeTokenProvider = Join-Path $temporaryPath 'fake-token-provider.ps1'
    @'
param([Parameter(Mandatory)][string]$DatabaseName)

$database = $DatabaseName
$logPath = Join-Path $env:PHASE2_TOKEN_LOG_DIRECTORY "$database.log"
Add-Content -Path $logPath -Value ([guid]::NewGuid().ToString('N')) -Encoding utf8
"token-$database"
'@ | Set-Content -Path $fakeTokenProvider -Encoding utf8
    $fakeSmokeTest = Join-Path $temporaryPath 'fake-smoke-test.ps1'
    @'
param(
    [string]$ServerName,
    [int]$Port,
    [string]$DatabaseName,
    [string]$AccessToken,
    [string]$TestPath
)
if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    throw 'The smoke test did not receive a refreshed access token.'
}
'@ | Set-Content -Path $fakeSmokeTest -Encoding utf8

    $approvedRoot = Join-Path $temporaryPath 'approved-review'
    $staleApprovedReports = Join-Path $approvedRoot 'all-database-reports'
    New-Item -ItemType Directory -Force -Path $staleApprovedReports | Out-Null
    Copy-Item `
        -Path (Join-Path $fixtures 'deploy-report-changed.xml') `
        -Destination (Join-Path $approvedRoot 'deploy-report.xml')
    Copy-Item `
        -Path (Join-Path $fixtures 'deploy-report-empty.xml') `
        -Destination (Join-Path $staleApprovedReports 'Shard02.deploy-report.xml')
    [ordered]@{
        environment = 'fixture'
        representativeDatabase = 'CanaryDb'
        targetDatabases = @('CanaryDb', 'Shard02', 'Shard03', 'Shard04')
        allDatabasePlansValidated = $false
        driftPolicy = 'Warn'
    } | ConvertTo-Json | Set-Content -Path (Join-Path $approvedRoot 'target-databases.json') -Encoding utf8

    $env:PHASE2_TOKEN_LOG_DIRECTORY = $tokenLogDirectory
    & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') `
        -ServerName 'sqlmi.example.test' `
        -DatabaseNames 'CanaryDb,Shard02,Shard03,Shard04' `
        -DacpacPath $fakeDacpac `
        -PublishProfilePath $fakeProfile `
        -SqlPackagePath $fakeSqlPackage `
        -ApprovedReportPath (Join-Path $approvedRoot 'deploy-report.xml') `
        -AccessTokenProviderPath $fakeTokenProvider `
        -SmokeTestScriptPath $fakeSmokeTest `
        -TestPath $fixtures `
        -ReportDirectory (Join-Path $temporaryPath 'current-reports') `
        -MaxParallel 3
    foreach ($database in @('CanaryDb', 'Shard02', 'Shard03', 'Shard04')) {
        $tokenCalls = @(Get-Content -Path (Join-Path $tokenLogDirectory "$database.log"))
        Assert-Equal $tokenCalls.Count 3 "Database '$database' must refresh its token before report, publish, and smoke test."
    }

    Write-Host 'All Phase 2 fixture and static tests passed.'
}
finally {
    Remove-Item Env:PHASE2_WARNING_PAYLOAD -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_PLAN_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_CHANGED_REPORT -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_TOKEN_LOG_DIRECTORY -ErrorAction SilentlyContinue
    if (Test-Path $temporaryPath) {
        Remove-Item -Path $temporaryPath -Recurse -Force
    }
}
