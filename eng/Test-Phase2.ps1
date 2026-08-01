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
    $rolloutTask = [regex]::Match(
        $templateText,
        '(?s)- task: AzureCLI@2\s+displayName: Deploy canary, test, then fan out(?<task>.*?)(?=\r?\n\s+- publish:)'
    ).Groups['task'].Value
    Assert-True `
        -Condition ($rolloutTask -match '(?m)^\s+keepAzSessionActive:\s*true\s*$') `
        -Message 'The long-running WIF rollout task must keep its Azure CLI session active.'
    Assert-True `
        -Condition (
            $templateText -match '(?s)displayName: Run advisory AI review of deployment SQL.*?Remove-Item.*?ai-review\.json.*?ai-review\.md.*?Invoke-AiDatabaseReview'
        ) `
        -Message 'The AI review task must remove known stale outputs before the current review.'

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
$connection = ($Arguments | Where-Object { $_ -like '/TargetConnectionString:*' }) -replace '^/TargetConnectionString:', ''
$database = [regex]::Match($connection, 'Initial Catalog=(?<database>[^;]+)').Groups['database'].Value
Add-Content -Path $env:PHASE2_PLAN_LOG -Value "ACTION:${action}:$database" -Encoding utf8
if ($action -eq 'DeployReport') {
    $reportFixture = if ($database -eq $env:PHASE2_DRIFT_DATABASE) {
        $env:PHASE2_DRIFT_REPORT
    }
    else {
        $env:PHASE2_CHANGED_REPORT
    }
    Copy-Item -Path $reportFixture -Destination $outputPath -Force
}
elseif ($action -eq 'Script') {
    $script = if ($database -eq $env:PHASE2_DESTRUCTIVE_DATABASE) {
        'DROP TABLE [app].[Danger];'
    }
    else {
        'SELECT 1;'
    }
    Set-Content -Path $outputPath -Value $script -Encoding utf8
}
$global:LASTEXITCODE = 0
'@ | Set-Content -Path $fakeSqlPackage -Encoding utf8
    $fakePlanTokenProvider = Join-Path $temporaryPath 'fake-plan-token-provider.ps1'
    @'
param([Parameter(Mandatory)][string]$DatabaseName)

Add-Content -Path $env:PHASE2_PLAN_LOG -Value "TOKEN:$DatabaseName" -Encoding utf8
"plan-token-$DatabaseName"
'@ | Set-Content -Path $fakePlanTokenProvider -Encoding utf8

    $reviewPath = Join-Path $temporaryPath 'deployment-review'
    $allReportsPath = Join-Path $reviewPath 'all-database-reports'
    New-Item -ItemType Directory -Force -Path $allReportsPath | Out-Null
    Set-Content -Path (Join-Path $reviewPath 'deploy.sql') -Value 'stale script' -Encoding utf8
    Set-Content -Path (Join-Path $allReportsPath 'Shard02.deploy-report.xml') -Value '<stale />' -Encoding utf8
    Set-Content -Path (Join-Path $reviewPath 'ai-review.json') -Value '{"risk":"high"}' -Encoding utf8
    Set-Content -Path (Join-Path $reviewPath 'ai-review.md') -Value '# stale AI review' -Encoding utf8
    $env:PHASE2_PLAN_LOG = $planLog
    $env:PHASE2_CHANGED_REPORT = Join-Path $fixtures 'deploy-report-changed.xml'
    & (Join-Path $PSScriptRoot 'New-DatabaseDeploymentPlan.ps1') `
        -ServerName 'sqlmi.example.test' `
        -DatabaseNames 'CanaryDb,Shard02' `
        -DacpacPath $fakeDacpac `
        -PublishProfilePath $fakeProfile `
        -SqlPackagePath $fakeSqlPackage `
        -AccessTokenProviderPath $fakePlanTokenProvider `
        -ReviewPath $reviewPath
    $planActions = @(Get-Content -Path $planLog)
    Assert-Equal $planActions[0] 'TOKEN:CanaryDb' 'Planning must refresh the token immediately before DeployReport.'
    Assert-Equal $planActions[1] 'ACTION:DeployReport:CanaryDb' 'The approved DeployReport must be captured first.'
    Assert-Equal $planActions[2] 'TOKEN:CanaryDb' 'Planning must refresh the token immediately before Script.'
    Assert-Equal $planActions[3] 'ACTION:Script:CanaryDb' 'The deployment script must be generated and gated after the approved DeployReport.'
    Assert-True `
        -Condition (-not (Test-Path $allReportsPath)) `
        -Message 'A run with all-database validation disabled must remove stale per-database reports.'
    Assert-True `
        -Condition (
            -not (Test-Path (Join-Path $reviewPath 'ai-review.json')) -and
            -not (Test-Path (Join-Path $reviewPath 'ai-review.md'))
        ) `
        -Message 'A new Plan must remove stale AI review outputs even when AI review is disabled.'

    Remove-Item -Path $planLog -Force
    $env:PHASE2_DESTRUCTIVE_DATABASE = 'Shard02'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'New-DatabaseDeploymentPlan.ps1') `
            -ServerName 'sqlmi.example.test' `
            -DatabaseNames 'CanaryDb,Shard02' `
            -DacpacPath $fakeDacpac `
            -PublishProfilePath $fakeProfile `
            -SqlPackagePath $fakeSqlPackage `
            -AccessTokenProviderPath $fakePlanTokenProvider `
            -ReviewPath $reviewPath `
            -ValidateAllDatabasePlans `
            -DatabasePlanDriftPolicy Warn
    } 'A destructive script for a non-representative database must fail the Plan even under Warn drift policy.'
    $fullPlanActions = @(Get-Content -Path $planLog)
    Assert-Equal ($fullPlanActions -join '|') `
        'TOKEN:CanaryDb|ACTION:DeployReport:CanaryDb|TOKEN:CanaryDb|ACTION:Script:CanaryDb|TOKEN:Shard02|ACTION:DeployReport:Shard02|TOKEN:Shard02|ACTION:Script:Shard02' `
        'Full validation must refresh before each report/script and gate every database in order.'
    Assert-True `
        -Condition (Test-Path (Join-Path $reviewPath 'all-database-scripts/Shard02.deploy.sql')) `
        -Message 'Full validation must retain each database deployment script in the review artifact.'
    Assert-True `
        -Condition (Test-Path (Join-Path $reviewPath 'all-database-policy-reports/Shard02.deployment-script-policy.md')) `
        -Message 'Full validation must retain each database policy report in the review artifact.'
    Assert-True `
        -Condition (-not (Test-Path (Join-Path $reviewPath 'target-databases.json'))) `
        -Message 'A failed shard gate must not leave a manifest that claims validation succeeded.'
    Remove-Item Env:PHASE2_DESTRUCTIVE_DATABASE
    Remove-Item -Path $planLog -Force
    & (Join-Path $PSScriptRoot 'New-DatabaseDeploymentPlan.ps1') `
        -ServerName 'sqlmi.example.test' `
        -DatabaseNames 'CanaryDb,Shard02' `
        -DacpacPath $fakeDacpac `
        -PublishProfilePath $fakeProfile `
        -SqlPackagePath $fakeSqlPackage `
        -AccessTokenProviderPath $fakePlanTokenProvider `
        -ReviewPath $reviewPath `
        -ValidateAllDatabasePlans `
        -DatabasePlanDriftPolicy Warn
    $successfulFullPlanActions = @(Get-Content -Path $planLog)
    Assert-Equal ($successfulFullPlanActions -join '|') `
        'TOKEN:CanaryDb|ACTION:DeployReport:CanaryDb|TOKEN:CanaryDb|ACTION:Script:CanaryDb|TOKEN:Shard02|ACTION:DeployReport:Shard02|TOKEN:Shard02|ACTION:Script:Shard02' `
        'A successful full Plan must refresh before all report and script actions.'
    $successfulManifest = Get-Content `
        -Path (Join-Path $reviewPath 'target-databases.json') `
        -Raw |
        ConvertFrom-Json
    Assert-True `
        -Condition (
            $successfulManifest.allDatabasePlansValidated -and
            $successfulManifest.allDatabaseScriptsGated -and
            @($successfulManifest.gatedDatabases).Count -eq 2
        ) `
        -Message 'A successful full Plan manifest must attest that every target script was gated.'
    $env:PHASE2_DRIFT_DATABASE = 'Shard02'
    $env:PHASE2_DRIFT_REPORT = Join-Path $fixtures 'deploy-report-different-operation.xml'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'New-DatabaseDeploymentPlan.ps1') `
            -ServerName 'sqlmi.example.test' `
            -DatabaseNames 'CanaryDb,Shard02' `
            -DacpacPath $fakeDacpac `
            -PublishProfilePath $fakeProfile `
            -SqlPackagePath $fakeSqlPackage `
            -AccessTokenProviderPath $fakePlanTokenProvider `
            -ReviewPath $reviewPath `
            -ValidateAllDatabasePlans `
            -DatabasePlanDriftPolicy Fail
    } 'Fail drift policy must reject a non-representative deployment plan.'
    Assert-True `
        -Condition (-not (Test-Path (Join-Path $reviewPath 'target-databases.json'))) `
        -Message 'A failed drift gate must not leave a manifest that claims validation succeeded.'
    Remove-Item Env:PHASE2_DRIFT_DATABASE
    Remove-Item Env:PHASE2_DRIFT_REPORT

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
    $approvedScripts = Join-Path $approvedRoot 'all-database-scripts'
    $approvedPolicyReports = Join-Path $approvedRoot 'all-database-policy-reports'
    New-Item -ItemType Directory -Force -Path $staleApprovedReports | Out-Null
    New-Item -ItemType Directory -Force -Path $approvedScripts | Out-Null
    New-Item -ItemType Directory -Force -Path $approvedPolicyReports | Out-Null
    Copy-Item `
        -Path (Join-Path $fixtures 'deploy-report-changed.xml') `
        -Destination (Join-Path $approvedRoot 'deploy-report.xml')
    foreach ($database in @('CanaryDb', 'Shard02', 'Shard03', 'Shard04')) {
        Copy-Item `
            -Path (Join-Path $fixtures 'deploy-report-changed.xml') `
            -Destination (Join-Path $staleApprovedReports "$database.deploy-report.xml")
        Set-Content -Path (Join-Path $approvedScripts "$database.deploy.sql") -Value 'SELECT 1;' -Encoding utf8
        Set-Content -Path (Join-Path $approvedPolicyReports "$database.deployment-script-policy.md") -Value '# passed' -Encoding utf8
    }
    [ordered]@{
        manifestVersion = 2
        environment = 'fixture'
        representativeDatabase = 'CanaryDb'
        targetDatabases = @('CanaryDb', 'Shard02', 'Shard03', 'Shard04')
        allDatabasePlansValidated = $true
        allDatabaseScriptsGated = $false
        gatedDatabases = @('CanaryDb')
        driftPolicy = 'Warn'
    } | ConvertTo-Json | Set-Content -Path (Join-Path $approvedRoot 'target-databases.json') -Encoding utf8
    Assert-Throws {
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
            -ReportDirectory (Join-Path $temporaryPath 'ungated-reports') `
            -MaxParallel 3
    } 'Deployment must reject a per-database report manifest unless every target script was gated.'
    [ordered]@{
        manifestVersion = 2
        environment = 'fixture'
        representativeDatabase = 'CanaryDb'
        targetDatabases = @('CanaryDb', 'Shard02', 'Shard03', 'Shard04')
        allDatabasePlansValidated = $true
        allDatabaseScriptsGated = $true
        gatedDatabases = @('CanaryDb', 'Shard02', 'Shard03', 'Shard04')
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
        -ReportDirectory (Join-Path $temporaryPath 'gated-current-reports') `
        -MaxParallel 3
    foreach ($database in @('CanaryDb', 'Shard02', 'Shard03', 'Shard04')) {
        $tokenCalls = @(Get-Content -Path (Join-Path $tokenLogDirectory "$database.log"))
        Assert-Equal $tokenCalls.Count 3 "Gated deployment '$database' must refresh before report, publish, and smoke test."
    }
    Remove-Item -Path (Join-Path $tokenLogDirectory '*.log') -Force
    Copy-Item `
        -Path (Join-Path $fixtures 'deploy-report-empty.xml') `
        -Destination (Join-Path $staleApprovedReports 'Shard02.deploy-report.xml') `
        -Force
    [ordered]@{
        manifestVersion = 2
        environment = 'fixture'
        representativeDatabase = 'CanaryDb'
        targetDatabases = @('CanaryDb', 'Shard02', 'Shard03', 'Shard04')
        allDatabasePlansValidated = $false
        allDatabaseScriptsGated = $false
        gatedDatabases = @('CanaryDb')
        driftPolicy = 'Warn'
    } | ConvertTo-Json | Set-Content -Path (Join-Path $approvedRoot 'target-databases.json') -Encoding utf8

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
    Remove-Item Env:PHASE2_DESTRUCTIVE_DATABASE -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_DRIFT_DATABASE -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_DRIFT_REPORT -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_TOKEN_LOG_DIRECTORY -ErrorAction SilentlyContinue
    if (Test-Path $temporaryPath) {
        Remove-Item -Path $temporaryPath -Recurse -Force
    }
}
