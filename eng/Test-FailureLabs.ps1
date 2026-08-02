[CmdletBinding()]
param(
    [switch]$IncludeDockerLabA,
    [int]$HostPort = 14334
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$labsRoot = Join-Path $repoRoot 'labs'
$temporaryPath = Join-Path ([IO.Path]::GetTempPath()) "sqlmi-failure-labs-$PID"
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
New-Item -ItemType Directory -Force -Path $temporaryPath | Out-Null

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-ChildPowerShell {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = @(
        & $pwsh -NoLogo -NoProfile -NonInteractive -File $ScriptPath @Arguments 2>&1
    )
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output -join [Environment]::NewLine
    }
}

function Assert-FailedWithPattern {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Description
    )

    Assert-True ($Result.ExitCode -ne 0) "$Description should return a non-zero exit code."
    Assert-True ($Result.Output -match $Pattern) "$Description did not contain the expected core error pattern."
}

function Invoke-DockerLabA {
    $containerId = $null
    $containerName = "sqlmi-phase4-lab-a-$PID"
    $password = "Local!Sql1_$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    $dacpac = [IO.Path]::Combine($repoRoot, 'artifacts', 'dacpac', 'App.Database.dacpac')
    $profile = [IO.Path]::Combine($repoRoot, 'pipelines', 'profiles', 'sqlmi-dev.publish.xml')
    $sqlPackageVersion = '170.4.83'
    $toolDirectory = Join-Path $temporaryPath 'sqlpackage'
    $sqlPackageName = if ($IsWindows) { 'sqlpackage.exe' } else { 'sqlpackage' }
    $sqlPackage = Join-Path $toolDirectory $sqlPackageName

    foreach ($command in @('docker', 'dotnet')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "$command is required for Lab A Docker validation."
        }
    }
    if (-not (Test-Path $dacpac -PathType Leaf)) {
        & (Join-Path $PSScriptRoot 'Build.ps1')
    }
    New-Item -ItemType Directory -Force -Path $toolDirectory | Out-Null
    & dotnet tool install `
        --tool-path $toolDirectory `
        Microsoft.SqlPackage `
        --version $sqlPackageVersion `
        --allow-roll-forward | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'SqlPackage installation failed for Lab A.'
    }

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
            throw 'Lab A SQL Server 2025 container failed to start.'
        }

        $sqlcmdPath = (& docker exec $containerId sh -c `
            'for path in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do if [ -x "$path" ]; then echo "$path"; exit 0; fi; done; command -v sqlcmd').Trim()
        if ($LASTEXITCODE -ne 0 -or -not $sqlcmdPath) {
            throw 'sqlcmd was not found in the Lab A container.'
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
        Assert-True $ready 'Lab A SQL Server did not become ready within 120 seconds.'

        & docker exec $containerId `
            $sqlcmdPath `
            -S localhost -U sa -P $password -C `
            -Q "CREATE DATABASE [Phase4LabA];" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Lab A database creation failed.'
        }

        $connectionBuilder = [System.Data.Common.DbConnectionStringBuilder]::new()
        $connectionBuilder['Server'] = "localhost,$HostPort"
        $connectionBuilder['Initial Catalog'] = 'Phase4LabA'
        $connectionBuilder['User ID'] = 'sa'
        $connectionBuilder['Pass' + 'word'] = $password
        $connectionBuilder['Encrypt'] = 'True'
        $connectionBuilder['TrustServerCertificate'] = 'True'
        $connectionBuilder['Connection Timeout'] = 30
        $connectionString = $connectionBuilder.ConnectionString
        & $sqlPackage `
            /Action:Publish `
            "/SourceFile:$dacpac" `
            "/TargetConnectionString:$connectionString" `
            "/Profile:$profile" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Lab A baseline DACPAC publish failed.'
        }

        Get-Content -Path (Join-Path $labsRoot 'lab-a-data-loss/setup-data-loss.sql') -Raw |
            & docker exec --interactive $containerId `
                $sqlcmdPath `
                -S localhost -U sa -P $password -C -b -d Phase4LabA
        if ($LASTEXITCODE -ne 0) {
            throw 'Lab A data-loss setup failed.'
        }

        $blockedOutput = @(
            & $sqlPackage `
                /Action:Publish `
                "/SourceFile:$dacpac" `
                "/TargetConnectionString:$connectionString" `
                "/Profile:$profile" `
                /p:DropObjectsNotInSource=True `
                /p:BlockOnPossibleDataLoss=True 2>&1
        ) -join [Environment]::NewLine
        Assert-True ($LASTEXITCODE -ne 0) 'Lab A destructive publish should return a non-zero exit code.'
        Assert-True `
            ($blockedOutput -match '(?i)data loss|rows were detected|schema update is terminating|데이터 손실|행이 검색|스키마 업데이트') `
            'Lab A destructive publish did not contain a recognized data-loss core pattern.'

        foreach ($scriptName in @('01-expand.sql', '02-migrate.sql', '03-contract.sql')) {
            Get-Content -Path ([IO.Path]::Combine($labsRoot, 'lab-a-data-loss', 'recovery', $scriptName)) -Raw |
                & docker exec --interactive $containerId `
                    $sqlcmdPath `
                    -S localhost -U sa -P $password -C -b -d Phase4LabA
            if ($LASTEXITCODE -ne 0) {
                throw "Lab A recovery script failed: $scriptName"
            }
        }

        & docker exec $containerId `
            $sqlcmdPath `
            -S localhost -U sa -P $password -C -b -d Phase4LabA `
            -Q "IF COL_LENGTH(N'app.FeatureFlag', N'LegacyDescription') IS NOT NULL OR COL_LENGTH(N'app.FeatureFlag', N'DescriptionV2') IS NULL THROW 51002, 'Lab A recovery verification failed.', 1;" |
            Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Lab A recovery verification failed.'
        }
        Write-Host 'Lab A Docker data-loss block and expand-migrate-contract recovery passed.'
    }
    finally {
        if ($containerId) {
            & docker rm --force $containerId | Out-Null
        }
    }
}

try {
    $confirmScript = Join-Path $PSScriptRoot 'Confirm-DeploymentPlan.ps1'
    $labB = Join-Path $labsRoot 'lab-b-approved-drift'
    $labBResult = Invoke-ChildPowerShell `
        -ScriptPath $confirmScript `
        -Arguments @(
            '-ApprovedReportPath', (Join-Path $labB 'approved-report.xml'),
            '-CurrentReportPath', (Join-Path $labB 'current-after-drift-report.xml'),
            '-CompareOperationsOnly'
        )
    Assert-FailedWithPattern `
        -Result $labBResult `
        -Pattern 'target database changed after approval' `
        -Description 'Lab B shard-aware approved/current report comparison'
    Write-Host 'Lab B approved-plan drift block passed.'

    $reviewScript = Join-Path $PSScriptRoot 'Invoke-AiDatabaseReview.ps1'
    $labC = Join-Path $labsRoot 'lab-c-ai-blocking'
    $advisoryOutput = Join-Path $temporaryPath 'lab-c-advisory.json'
    $labCArguments = @(
        '-ReviewInputPath', (Join-Path $labC 'risky-change.sql'),
        '-ValidateOnlyResponsePath', (Join-Path $labC 'blocking-review.json'),
        '-OutputPath', $advisoryOutput
    )
    $labCAdvisory = Invoke-ChildPowerShell -ScriptPath $reviewScript -Arguments $labCArguments
    Assert-True ($labCAdvisory.ExitCode -eq 0) 'Lab C advisory mode should return exit code 0.'
    Assert-True (Test-Path $advisoryOutput -PathType Leaf) 'Lab C advisory JSON artifact was not created.'
    $advisory = Get-Content -Path $advisoryOutput -Raw | ConvertFrom-Json
    Assert-True (@($advisory.blockingFindings).Count -eq 1) 'Lab C advisory artifact should retain one blocking finding.'

    $labCBlocking = Invoke-ChildPowerShell `
        -ScriptPath $reviewScript `
        -Arguments ($labCArguments + '-FailOnBlockingFindings')
    Assert-FailedWithPattern `
        -Result $labCBlocking `
        -Pattern 'AI review reported 1 blocking finding' `
        -Description 'Lab C blocking AI review'
    Write-Host 'Lab C advisory and blocking modes passed.'

    $policyScript = Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1'
    $destructiveScript = [IO.Path]::Combine($labsRoot, 'samples', 'destructive-deploy.sql')
    $labD = Join-Path $labsRoot 'lab-d-destructive-gate'
    $blockedReport = Join-Path $temporaryPath 'lab-d-blocked.md'
    $labDBlocked = Invoke-ChildPowerShell `
        -ScriptPath $policyScript `
        -Arguments @(
            '-ScriptPath', $destructiveScript,
            '-AllowlistPath', ([IO.Path]::Combine($PSScriptRoot, 'policy', 'deploy-allowlist.json')),
            '-ReportPath', $blockedReport
        )
    Assert-FailedWithPattern `
        -Result $labDBlocked `
        -Pattern 'policy failed with 1 error' `
        -Description 'Lab D destructive deployment gate'
    Assert-True ((Get-Content -Path $blockedReport -Raw) -match 'DEPLOY001') 'Lab D blocked report should contain DEPLOY001.'

    $allowedReport = Join-Path $temporaryPath 'lab-d-allowed.md'
    $labDAllowed = Invoke-ChildPowerShell `
        -ScriptPath $policyScript `
        -Arguments @(
            '-ScriptPath', $destructiveScript,
            '-AllowlistPath', (Join-Path $labD 'allowlist-active.json'),
            '-ReportPath', $allowedReport
        )
    Assert-True ($labDAllowed.ExitCode -eq 0) 'Lab D active allowlist should return exit code 0.'
    Assert-True ((Get-Content -Path $allowedReport -Raw) -match 'allowlisted: TRAINING-PHASE4-LABD-001') 'Lab D active allowlist was not recorded in the report.'

    $expiredReport = Join-Path $temporaryPath 'lab-d-expired.md'
    $labDExpired = Invoke-ChildPowerShell `
        -ScriptPath $policyScript `
        -Arguments @(
            '-ScriptPath', $destructiveScript,
            '-AllowlistPath', (Join-Path $labD 'allowlist-expired.json'),
            '-ReportPath', $expiredReport
        )
    Assert-FailedWithPattern `
        -Result $labDExpired `
        -Pattern 'policy failed with 1 error' `
        -Description 'Lab D expired allowlist'
    Assert-True ((Get-Content -Path $expiredReport -Raw) -match 'Expired allowlist entries') 'Lab D expired allowlist report section is missing.'
    Write-Host 'Lab D block, active allowlist, and expired allowlist modes passed.'

    if ($IncludeDockerLabA) {
        Invoke-DockerLabA
    }

    Write-Host 'All requested Phase 4 failure lab tests passed.'

    # Negative test cases leave a non-zero $LASTEXITCODE behind. The Azure
    # Pipelines PowerShell task dot-sources this script, so that stale value
    # would otherwise be reported as the task result.
    exit 0
}
finally {
    if (Test-Path $temporaryPath) {
        Remove-Item -Path $temporaryPath -Recurse -Force
    }
}
