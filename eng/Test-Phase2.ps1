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

function Invoke-ExternalScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )
    $output = @(
        & $pwsh -NoProfile -NonInteractive -File $ScriptPath @Arguments 2>&1
    )
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output -join [Environment]::NewLine
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

    $confirmScript = Join-Path $PSScriptRoot 'Confirm-DeploymentPlan.ps1'
    $identicalPlan = Invoke-ExternalScript $confirmScript @(
        '-ApprovedReportPath', (Join-Path $fixtures 'deploy-report-changed.xml'),
        '-CurrentReportPath', (Join-Path $fixtures 'deploy-report-changed.xml')
    )
    Assert-True ($identicalPlan.ExitCode -eq 0) 'An unchanged approved deployment plan should pass.'
    $addedOperation = Invoke-ExternalScript $confirmScript @(
        '-ApprovedReportPath', (Join-Path $fixtures 'deploy-report-empty.xml'),
        '-CurrentReportPath', (Join-Path $fixtures 'deploy-report-changed.xml')
    )
    Assert-True ($addedOperation.ExitCode -ne 0) 'An operation added after approval should be blocked.'
    $differentOperation = Invoke-ExternalScript $confirmScript @(
        '-ApprovedReportPath', (Join-Path $fixtures 'deploy-report-changed.xml'),
        '-CurrentReportPath', (Join-Path $fixtures 'deploy-report-different-operation.xml')
    )
    Assert-True ($differentOperation.ExitCode -ne 0) 'A changed operation type should be blocked.'
    $representativePlan = Invoke-ExternalScript $confirmScript @(
        '-ApprovedReportPath', (Join-Path $fixtures 'deploy-report-changed.xml'),
        '-CurrentReportPath', (Join-Path $fixtures 'deploy-report-changed-shard.xml')
    )
    Assert-True ($representativePlan.ExitCode -ne 0) 'Representative database comparison should include target metadata.'
    $nonRepresentativePlan = Invoke-ExternalScript $confirmScript @(
        '-ApprovedReportPath', (Join-Path $fixtures 'deploy-report-changed.xml'),
        '-CurrentReportPath', (Join-Path $fixtures 'deploy-report-changed-shard.xml'),
        '-CompareOperationsOnly'
    )
    Assert-True ($nonRepresentativePlan.ExitCode -eq 0) 'Non-representative comparison should compare operations only.'

    $reviewScript = Join-Path $PSScriptRoot 'Invoke-AiDatabaseReview.ps1'
    $validReviewPath = Join-Path $temporaryPath 'valid-review.json'
    $validReview = Invoke-ExternalScript $reviewScript @(
        '-ValidateOnlyResponsePath', (Join-Path $fixtures 'ai-review-single.json'),
        '-OutputPath', $validReviewPath
    )
    Assert-True ($validReview.ExitCode -eq 0) 'A valid offline AI response should pass.'
    $validReviewResult = Get-Content $validReviewPath -Raw | ConvertFrom-Json
    Assert-True ($validReviewResult.risk -eq 'low') 'The valid offline AI response should be written.'
    $invalidReview = Invoke-ExternalScript $reviewScript @(
        '-ValidateOnlyResponsePath', (Join-Path $fixtures 'ai-review-malformed.json'),
        '-OutputPath', (Join-Path $temporaryPath 'invalid-review.json')
    )
    Assert-True ($invalidReview.ExitCode -ne 0) 'An AI response that violates the schema should fail.'

    $chunkedInput = Join-Path $temporaryPath 'chunked.sql'
    Set-Content -Path $chunkedInput -Encoding utf8 -Value @(
        "SELECT N'$([string]::new('a', 700))' AS [FirstBatch];",
        'GO',
        "SELECT N'$([string]::new('b', 700))' AS [SecondBatch];",
        'GO',
        "SELECT N'$([string]::new('c', 700))' AS [ThirdBatch];"
    )
    $chunkedOutput = Join-Path $temporaryPath 'chunked-review.json'
    $chunkedReview = Invoke-ExternalScript $reviewScript @(
        '-ReviewInputPath', $chunkedInput,
        '-MaxInputCharacters', '1000',
        '-ValidateOnlyResponsePath', (Join-Path $fixtures 'ai-review-multi.json'),
        '-OutputPath', $chunkedOutput
    )
    Assert-True ($chunkedReview.ExitCode -eq 0) 'GO-delimited batches should produce bounded review chunks.'
    $chunkedResult = Get-Content $chunkedOutput -Raw | ConvertFrom-Json
    Assert-True (@($chunkedResult.blockingFindings).Count -eq 2) 'Duplicate blocking findings should retain the first occurrence only.'
    Assert-True (@($chunkedResult.advisories).Count -eq 2) 'Duplicate advisories should retain the first occurrence only.'
    Assert-True ($chunkedResult.blockingFindings[0].recommendation -eq 'Review the table change.') 'Deduplication should preserve the first blocking finding.'

    $oversizeInput = Join-Path $temporaryPath 'oversize.sql'
    Set-Content -Path $oversizeInput -Encoding utf8 -Value (
        "SELECT N'$([string]::new('x', 1500))' AS [OversizeBatch];"
    )
    $oversizeReview = Invoke-ExternalScript $reviewScript @(
        '-ReviewInputPath', $oversizeInput,
        '-MaxInputCharacters', '1000',
        '-ValidateOnlyResponsePath', (Join-Path $fixtures 'ai-review-two.json'),
        '-OutputPath', (Join-Path $temporaryPath 'oversize-review.json')
    )
    Assert-True ($oversizeReview.ExitCode -eq 0) 'An oversized single batch should use the character fallback.'
    Assert-True ($oversizeReview.Output -match 'exceeds MaxInputCharacters') 'The oversized batch fallback should be logged.'

    $sqlCredentialSyntax = Join-Path $temporaryPath 'credential-syntax.sql'
    Set-Content -Path $sqlCredentialSyntax -Encoding utf8 -Value @'
DECLARE @Password nvarchar(128);
CREATE LOGIN [variable_login] WITH PASSWORD = @Password;
CREATE LOGIN [sqlcmd_login] WITH PASSWORD = N'$(LoginPassword)';
CREATE LOGIN [literal_login] WITH PASSWORD = N'Example-Only-2026!';
'@
    $syntaxReviewPath = Join-Path $temporaryPath 'credential-syntax-review.json'
    $syntaxReview = Invoke-ExternalScript $reviewScript @(
        '-ReviewInputPath', $sqlCredentialSyntax,
        '-ValidateOnlyResponsePath', (Join-Path $fixtures 'ai-review-single.json'),
        '-OutputPath', $syntaxReviewPath
    )
    Assert-True ($syntaxReview.ExitCode -eq 0) 'Normal T-SQL credential syntax should not stop AI review.'
    Assert-True (@((Get-Content $syntaxReviewPath -Raw | ConvertFrom-Json).advisories).Count -eq 0) 'Normal T-SQL credential syntax should not be reported as a likely secret.'

    $possibleSecret = @('Abcdef', '123456', '!@#') -join ''
    $secretInput = Join-Path $temporaryPath 'possible-secret.txt'
    Set-Content -Path $secretInput -Encoding utf8 -Value "api_key = $possibleSecret"
    $secretReviewPath = Join-Path $temporaryPath 'possible-secret-review.json'
    $secretReview = Invoke-ExternalScript $reviewScript @(
        '-ReviewInputPath', $secretInput,
        '-ValidateOnlyResponsePath', (Join-Path $fixtures 'ai-review-single.json'),
        '-OutputPath', $secretReviewPath
    )
    Assert-True ($secretReview.ExitCode -eq 0) 'A possible secret should remain advisory.'
    Assert-True (@((Get-Content $secretReviewPath -Raw | ConvertFrom-Json).advisories).Count -eq 1) 'A sufficiently composed credential literal should produce one advisory.'
    $reviewScriptText = Get-Content $reviewScript -Raw
    Assert-True ($reviewScriptText -match 'max_output_tokens\s*=') 'Responses requests should set max_output_tokens.'
    Assert-True ($reviewScriptText -match '(?s)text\s*=\s*@\{.*?format\s*=\s*@\{.*?type\s*=\s*''json_schema''.*?strict\s*=\s*\$true') 'Responses requests should use a strict text.format JSON schema.'

    Import-Module (Join-Path $PSScriptRoot 'SqlCmd.Common.psm1') -Force
    Assert-True (Test-SqlHasNoDynamicExecution -Text 'SELECT 1;') 'Static SQL should pass the no-dynamic-execution predicate.'
    Assert-True (-not (Test-SqlHasNoDynamicExecution -Text 'EXEC(@statement);')) 'Dynamic SQL should fail the no-dynamic-execution predicate.'

    $exp = [DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeSeconds()
    $payloadJson = @{ exp = $exp } | ConvertTo-Json -Compress
    $payloadSegment = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($payloadJson)
    ).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $shortLivedToken = "header.$payloadSegment.signature"
    $tokenProvider = Join-Path $temporaryPath 'token-provider.ps1'
    Set-Content -Path $tokenProvider -Encoding utf8 -Value @"
param([string]`$DatabaseName)
Write-Output '$shortLivedToken'
"@
    $sqlPackageMarker = Join-Path $temporaryPath 'sqlpackage-called.txt'
    $fakeSqlPackage = Join-Path $temporaryPath 'SqlPackage.ps1'
    Set-Content -Path $fakeSqlPackage -Encoding utf8 -Value @"
param([Parameter(ValueFromRemainingArguments)][object[]]`$Arguments)
Set-Content -Path '$sqlPackageMarker' -Value 'called'
"@
    $tokenSummary = Join-Path $temporaryPath 'token-summary.md'
    $tokenPreflight = Invoke-ExternalScript (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @(
        '-ServerName', 'test.example',
        '-DatabaseName', 'SampleDb',
        '-DacpacPath', (Join-Path $fixtures 'deploy-report-empty.xml'),
        '-PublishProfilePath', (Join-Path $fixtures 'deploy-report-empty.xml'),
        '-SqlPackagePath', $fakeSqlPackage,
        '-ApprovedReportPath', (Join-Path $fixtures 'deploy-report-changed.xml'),
        '-AccessTokenProviderPath', $tokenProvider,
        '-TestPath', $temporaryPath,
        '-SummaryPath', $tokenSummary,
        '-MinimumTokenLifetimeMinutes', '20'
    )
    Assert-True ($tokenPreflight.ExitCode -ne 0) 'A short-lived token should stop deployment.'
    Assert-True (-not (Test-Path $sqlPackageMarker)) 'Token preflight must stop before SqlPackage is called.'
    Assert-True ($tokenPreflight.Output -match 'remaining lifetime is below') 'Token preflight should explain the failure.'
    Assert-True ((Get-Content $tokenSummary -Raw) -match 'Remaining lifetime at rollout start') 'Token lifetime should be recorded in the deployment summary.'

    $pipeline = Get-Content (Join-Path $repoRoot 'azure-pipelines.yml') -Raw
    $deployTemplate = Get-Content (Join-Path $repoRoot 'pipelines/templates/deploy-stage.yml') -Raw

    $deploy = Get-Content (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') -Raw
    Assert-True (@([regex]::Matches($deploy, '& \$AccessTokenProviderPath')).Count -eq 1) 'Database rollout must acquire one token before fan-out.'
    Assert-True ($deploy -notmatch '& \$WorkerContext\.AccessTokenProviderPath') 'Workers must not invoke the token provider.'
    Assert-True ($deploy -match "\[string\]\`$DeploymentMode = 'Publish'") 'Publish must be the script default.'
    Assert-True ($deploy -match "ValidateSet\('Publish', 'ValidatedScript'\)") 'ValidatedScript must remain an explicit mode.'
    Assert-True ($pipeline -match 'name:\s*deploymentMode[\s\S]*?default:\s*Publish') 'Pipeline deploymentMode must default to Publish.'
    Assert-True ($deployTemplate -match '-DeploymentMode\s+"\$\{\{\s*parameters\.deploymentMode\s*\}\}"') 'Deploy stage must pass deploymentMode.'
    Assert-True ($deploy -match "Test-DeployedDatabase\.ps1") 'Database rollout must retain the Invoke-Sqlcmd smoke test.'

    Write-Host 'All education-slim Phase 2 self-tests passed.'

    # Negative test cases leave a non-zero $LASTEXITCODE behind. The Azure
    # Pipelines PowerShell task dot-sources this script, so that stale value
    # would otherwise be reported as the task result.
    exit 0
}
finally {
    if (Test-Path $temporaryPath) {
        Remove-Item $temporaryPath -Recurse -Force
    }
}
