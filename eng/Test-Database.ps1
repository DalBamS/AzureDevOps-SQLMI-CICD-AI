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
$sqlPackageVersion = '170.4.83'
$toolCacheRoot = if ($env:AGENT_TEMPDIRECTORY) {
    $env:AGENT_TEMPDIRECTORY
}
else {
    [IO.Path]::GetTempPath()
}
$toolDirectory = Join-Path $toolCacheRoot "sqlpackage-$sqlPackageVersion"
$publishProfile = [IO.Path]::Combine($repoRoot, 'pipelines', 'profiles', 'sqlmi-dev.publish.xml')
$sqlServerModuleVersion = '22.4.5.1'
$containerId = $null
$sqlcmdPath = $null
$exactScriptTestPath = Join-Path ([IO.Path]::GetTempPath()) "sqlmi-exact-script-$PID"

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
$sqlServerModule = Get-Module -ListAvailable -Name SqlServer |
    Where-Object Version -eq $sqlServerModuleVersion |
    Select-Object -First 1
if (-not $sqlServerModule) {
    Install-Module `
        -Name SqlServer `
        -RequiredVersion $sqlServerModuleVersion `
        -Scope CurrentUser `
        -Repository PSGallery `
        -Force `
        -AllowClobber
}
Import-Module SqlServer -RequiredVersion $sqlServerModuleVersion -Force
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'SqlCmd.Common.psm1')) -Force

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

    $goParserCases = @(
        @{ Name = 'separator'; Sql = "SELECT 1;`nGO`nSELECT 2;"; ExpectedBatches = 2 },
        @{ Name = 'zero'; Sql = "SELECT 1;`nGO 0`nSELECT 2;"; ExpectedBatches = 2 },
        @{ Name = 'leading-zero'; Sql = "SELECT 1;`nGO 01`nSELECT 2;"; ExpectedBatches = 2 },
        @{ Name = 'int32-max'; Sql = "SELECT 1;`nGO 2147483647`nSELECT 2;"; ExpectedBatches = 2 },
        @{ Name = 'compact-comment'; Sql = "SELECT 1;`nGO--comment`nSELECT 2;"; ExpectedBatches = 2 },
        @{ Name = 'compact-count-comment'; Sql = "SELECT 1;`nGO 1--comment`nSELECT 2;"; ExpectedBatches = 2 },
        @{ Name = 'attached-plus'; Sql = "SELECT 1;`nGO+1`nSELECT 2;"; ExpectedBatches = 1 },
        @{ Name = 'attached-zero'; Sql = "SELECT 1;`nGO0`nSELECT 2;"; ExpectedBatches = 1 },
        @{ Name = 'attached-decimal'; Sql = "SELECT 1;`nGO.1`nSELECT 2;"; ExpectedBatches = 1 },
        @{ Name = 'attached-slash'; Sql = "SELECT 1;`nGO/1`nSELECT 2;"; Error = $true },
        @{ Name = 'attached-dollar'; Sql = 'SELECT 1;' + "`n" + 'GO$x' + "`nSELECT 2;"; Error = $true },
        @{ Name = 'attached-bang'; Sql = "SELECT 1;`nGO!x`nSELECT 2;"; Error = $true },
        @{ Name = 'attached-parenthesis'; Sql = "SELECT 1;`nGO(x)`nSELECT 2;"; Error = $true },
        @{ Name = 'overflow'; Sql = "SELECT 1;`nGO 2147483648`nSELECT 2;"; Error = $true },
        @{ Name = 'negative'; Sql = "SELECT 1;`nGO -1`nSELECT 2;"; Error = $true },
        @{ Name = 'compact-negative'; Sql = "SELECT 1;`nGO-1`nSELECT 2;"; Error = $true },
        @{ Name = 'positive-sign'; Sql = "SELECT 1;`nGO +1`nSELECT 2;"; Error = $true },
        @{ Name = 'decimal-count'; Sql = "SELECT 1;`nGO 1.5`nSELECT 2;"; Error = $true },
        @{ Name = 'multiline-string'; Sql = "PRINT N'first`nGO`nlast';"; ExpectedBatches = 1 },
        @{ Name = 'nested-comment'; Sql = "/* outer /* nested`nGO`n*/ outer */`nSELECT 1;"; ExpectedBatches = 1 },
        @{ Name = 'bracket-identifier'; Sql = "SELECT 1 AS [first`nGO`nlast];"; ExpectedBatches = 1 },
        @{ Name = 'quoted-identifier'; Sql = "SELECT 1 AS `"first`nGO`nlast`";"; ExpectedBatches = 1 },
        @{ Name = 'line-comment'; Sql = "-- GO`nSELECT 1;"; ExpectedBatches = 1 }
    )
    foreach ($case in $goParserCases) {
        $batchParser = [Microsoft.SqlTools.ServiceLayer.BatchParser.BatchParserWrapper]::new()
        $managedError = $false
        try {
            $conditions = [Microsoft.SqlTools.ServiceLayer.BatchParser.ExecutionEngineCode.ExecutionEngineConditions]::new()
            $conditions.IsSqlCmd = $true
            $conditions.BatchSeparator = 'GO'
            $parsedBatches = @(
                $batchParser.GetBatches($case.Sql, $conditions)
            )
        }
        catch {
            $managedError = $true
        }
        finally {
            $batchParser.Dispose()
        }

        $adapterError = $false
        try {
            $adapterBatches = @(SqlCmd.Common\Get-SqlBatch -Text $case.Sql)
        }
        catch {
            $adapterError = $true
        }
        if ($managedError -ne $adapterError) {
            throw "GO adapter diverged from the managed parser for '$($case.Name)'."
        }
        $expectedError = $case.ContainsKey('Error') -and $case.Error
        if ($managedError -ne $expectedError) {
            throw "Managed parser returned an unexpected error classification for '$($case.Name)'."
        }
        if (-not $expectedError) {
            if (
                $parsedBatches.Count -ne $case.ExpectedBatches -or
                $adapterBatches.Count -ne $parsedBatches.Count
            ) {
                throw "GO adapter returned unexpected batches for '$($case.Name)'."
            }
            for ($index = 0; $index -lt $parsedBatches.Count; $index++) {
                if (
                    $adapterBatches[$index].Text -cne $parsedBatches[$index].BatchText -or
                    $adapterBatches[$index].StartLine -ne $parsedBatches[$index].StartLine
                ) {
                    throw "GO adapter metadata diverged for '$($case.Name)'."
                }
            }
        }
    }

    foreach ($case in @(
        @{ Count = '0'; ExpectedExecutionCount = 1 },
        @{ Count = '01'; ExpectedExecutionCount = 1 },
        @{ Count = '2147483647'; ExpectedExecutionCount = 2147483647 }
    )) {
        $batchParser = [Microsoft.SqlTools.ServiceLayer.BatchParser.BatchParserWrapper]::new()
        try {
            $conditions = [Microsoft.SqlTools.ServiceLayer.BatchParser.ExecutionEngineCode.ExecutionEngineConditions]::new()
            $conditions.IsSqlCmd = $true
            $conditions.BatchSeparator = 'GO'
            $parsedBatches = @(
                $batchParser.GetBatches(
                    "SELECT 1;`nGO $($case.Count)`nSELECT 2;",
                    $conditions
                )
            )
            if (
                $parsedBatches.Count -ne 2 -or
                $parsedBatches[0].BatchExecutionCount -ne $case.ExpectedExecutionCount
            ) {
                throw "Managed parser returned unexpected GO $($case.Count) batch metadata."
            }
        }
        finally {
            $batchParser.Dispose()
        }
    }
    foreach ($count in @('2147483648', '999999999999999999999999999999999999')) {
        $batchParser = [Microsoft.SqlTools.ServiceLayer.BatchParser.BatchParserWrapper]::new()
        $overflowRejected = $false
        try {
            $conditions = [Microsoft.SqlTools.ServiceLayer.BatchParser.ExecutionEngineCode.ExecutionEngineConditions]::new()
            $conditions.IsSqlCmd = $true
            $conditions.BatchSeparator = 'GO'
            [void]$batchParser.GetBatches(
                "SELECT 1;`nGO $count`nSELECT 2;",
                $conditions
            )
        }
        catch {
            $overflowRejected = $true
        }
        finally {
            $batchParser.Dispose()
        }
        if (-not $overflowRejected) {
            throw "Managed parser unexpectedly accepted overflowing GO count '$count'."
        }
    }

    $goProbeTable = "SqlMiGoProbe_$PID"
    $goProbeArguments = @{
        ServerInstance = "tcp:localhost,$HostPort"
        Database = 'master'
        Username = 'sa'
        Password = $password
        Encrypt = 'Mandatory'
        TrustServerCertificate = $true
        ConnectionTimeout = 30
        QueryTimeout = $SqlCommandTimeout
        ErrorAction = 'Stop'
    }
    $goProbeRows = @(
        Invoke-Sqlcmd @goProbeArguments -Query @"
CREATE TABLE [tempdb].[dbo].[$goProbeTable] ([Label] nvarchar(40) NOT NULL);
GO-- compact trailing comment
INSERT [tempdb].[dbo].[$goProbeTable] VALUES (N'before-zero');
GO 0-- compact zero-count comment
INSERT [tempdb].[dbo].[$goProbeTable] VALUES (N'after-zero');
GO
INSERT [tempdb].[dbo].[$goProbeTable] VALUES (N'before-double-zero');
GO 00-- compact leading-zero comment
INSERT [tempdb].[dbo].[$goProbeTable] VALUES (N'after-double-zero');
`t gO`t01-- compact mixed-whitespace comment
INSERT [tempdb].[dbo].[$goProbeTable] VALUES (N'after-leading-zero');
GO -- spaced trailing comment
SELECT [Label] FROM [tempdb].[dbo].[$goProbeTable] ORDER BY [Label];
"@
    )
    $goProbeLabels = @($goProbeRows | ForEach-Object { [string]$_.Label })
    if (
        ($goProbeLabels -join '|') -cne
            'after-double-zero|after-leading-zero|after-zero'
    ) {
        throw "Invoke-Sqlcmd GO count grammar probe returned unexpected rows: $($goProbeLabels -join ', ')"
    }
    $invalidGoRejected = $false
    try {
        Invoke-Sqlcmd @goProbeArguments -Query "SELECT 1;`nGO 1x`nSELECT 2;" |
            Out-Null
    }
    catch {
        $invalidGoRejected = $true
    }
    if (-not $invalidGoRejected) {
        throw 'Invoke-Sqlcmd unexpectedly accepted a GO count with an alphabetic suffix.'
    }
    Invoke-Sqlcmd @goProbeArguments -Query "DROP TABLE [tempdb].[dbo].[$goProbeTable];"
    Write-Host 'Managed parser adapter and Invoke-Sqlcmd GO grammar probes passed.'

    & docker exec $containerId `
        $sqlcmdPath `
        -S localhost -U sa -P $password -C `
        -Q "IF DB_ID(N'AppDb_Test') IS NULL CREATE DATABASE [AppDb_Test];"
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the integration test database.'
    }

    $connectionString = "Server=localhost,$HostPort;Initial Catalog=AppDb_Test;User ID=sa;Password=$password;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
    New-Item -ItemType Directory -Force -Path $exactScriptTestPath | Out-Null
    $initialScriptPath = Join-Path $exactScriptTestPath 'initial.deploy.sql'
    $failedPostDeploymentScriptPath = Join-Path $exactScriptTestPath 'failed-postdeploy.deploy.sql'
    $initialPolicyPath = Join-Path $exactScriptTestPath 'initial.policy.md'
    & $sqlPackage `
        /Action:Script `
        "/SourceFile:$dacpac" `
        "/TargetConnectionString:$connectionString" `
        "/OutputPath:$initialScriptPath" `
        "/Profile:$publishProfile" `
        "/p:CommandTimeout=$SqlCommandTimeout"
    if ($LASTEXITCODE -ne 0) {
        throw 'Initial exact deployment script generation failed.'
    }
    & ([IO.Path]::Combine($PSScriptRoot, 'Test-DeploymentScript.ps1')) `
        -ScriptPath $initialScriptPath `
        -ReportPath $initialPolicyPath
    Import-Module ([IO.Path]::Combine($PSScriptRoot, 'Phase2.Common.psm1')) -Force
    Import-Module ([IO.Path]::Combine($PSScriptRoot, 'SqlCmd.Common.psm1')) -Force
    $approvedPostDeployment = Get-DacFxPostDeploymentPayload -Path $initialScriptPath
    $approvedPostDeploymentSemantics = Get-DacFxPostDeploymentSemantic `
        -Path $initialScriptPath `
        -TargetDatabase AppDb_Test
    function Invoke-LocalSanitizedScript {
        param([Parameter(Mandatory)][string]$Path)

        $resolution = Resolve-SqlCmdScript -Path $Path
        Invoke-Sqlcmd `
            -ServerInstance "tcp:localhost,$HostPort" `
            -Database AppDb_Test `
            -Username sa `
            -Password $password `
            -Query $resolution.SanitizedText `
            -DisableCommands `
            -DisableVariables `
            -AbortOnError `
            -Encrypt Mandatory `
            -TrustServerCertificate `
            -ConnectionTimeout 30 `
            -QueryTimeout $SqlCommandTimeout `
            -ErrorAction Stop
    }
    $failedPostDeploymentScript = [regex]::Replace(
        (Get-Content -Path $initialScriptPath -Raw),
        '(?ms)(^-- SQLMI-CICD POSTDEPLOY START v1[ \t]*\r?\n).*?(^-- SQLMI-CICD POSTDEPLOY END v1[ \t]*\r?$)',
        "`${1}THROW 51000, 'Intentional post-deployment retry fixture failure.', 1;`r`n`${2}"
    )
    if (
        $failedPostDeploymentScript -notmatch 'Intentional post-deployment retry fixture failure' -or
        $failedPostDeploymentScript -ceq (Get-Content -Path $initialScriptPath -Raw)
    ) {
        throw 'Unable to construct the intentional post-deployment failure fixture.'
    }
    Set-Content `
        -Path $failedPostDeploymentScriptPath `
        -Value $failedPostDeploymentScript `
        -NoNewline `
        -Encoding utf8
    $postDeploymentFailed = $false
    try {
        Invoke-LocalSanitizedScript -Path $failedPostDeploymentScriptPath
    }
    catch {
        $postDeploymentFailed = $true
    }
    if (-not $postDeploymentFailed) {
        throw 'The intentional post-deployment failure fixture did not fail.'
    }

    $seedQueryArguments = @{
        ServerInstance = "tcp:localhost,$HostPort"
        Database = 'AppDb_Test'
        Username = 'sa'
        Password = $password
        Encrypt = 'Mandatory'
        TrustServerCertificate = $true
        ConnectionTimeout = 30
        QueryTimeout = $SqlCommandTimeout
        ErrorAction = 'Stop'
    }
    $initialSeedCount = (
        Invoke-Sqlcmd @seedQueryArguments -Query @'
SELECT COUNT_BIG(*) AS [SeedCount]
FROM [app].[FeatureFlag]
WHERE [FlagName] = N'database-cicd-ready';
'@
    ).SeedCount
    if ($initialSeedCount -ne 0) {
        throw 'The intentional post-deployment failure fixture unexpectedly inserted seed data.'
    }

    $retryReportPath = Join-Path $exactScriptTestPath 'retry.deploy-report.xml'
    $retryScriptPath = Join-Path $exactScriptTestPath 'retry.deploy.sql'
    $retryPolicyPath = Join-Path $exactScriptTestPath 'retry.policy.md'
    & $sqlPackage `
        /Action:DeployReport `
        "/SourceFile:$dacpac" `
        "/TargetConnectionString:$connectionString" `
        "/OutputPath:$retryReportPath" `
        "/Profile:$publishProfile" `
        "/p:CommandTimeout=$SqlCommandTimeout"
    if ($LASTEXITCODE -ne 0) {
        throw 'Retry DeployReport generation failed.'
    }
    if (Test-DeployReportHasChanges -Path $retryReportPath) {
        throw 'The retry DeployReport should contain no schema operations.'
    }
    & $sqlPackage `
        /Action:Script `
        "/SourceFile:$dacpac" `
        "/TargetConnectionString:$connectionString" `
        "/OutputPath:$retryScriptPath" `
        "/Profile:$publishProfile" `
        "/p:CommandTimeout=$SqlCommandTimeout"
    if ($LASTEXITCODE -ne 0) {
        throw 'Retry exact deployment script generation failed.'
    }
    & ([IO.Path]::Combine($PSScriptRoot, 'Test-DeploymentScript.ps1')) `
        -ScriptPath $retryScriptPath `
        -ReportPath $retryPolicyPath
    $retryPostDeployment = Get-DacFxPostDeploymentPayload `
        -Path $retryScriptPath `
        -RequirePostDeploymentOnly
    if ($retryPostDeployment.Sha256 -cne $approvedPostDeployment.Sha256) {
        throw 'The post-deployment-only retry payload differs from the approved initial payload.'
    }
    $retryPostDeploymentSemantics = Get-DacFxPostDeploymentSemantic `
        -Path $retryScriptPath `
        -TargetDatabase AppDb_Test `
        -RuntimeVariableContract $approvedPostDeploymentSemantics.RuntimeVariableContract
    if (
        $retryPostDeploymentSemantics.SemanticPayloadSha256 -cne
            $approvedPostDeploymentSemantics.SemanticPayloadSha256 -or
        $retryPostDeploymentSemantics.CanonicalVariableMapSha256 -cne
            $approvedPostDeploymentSemantics.CanonicalVariableMapSha256
    ) {
        throw 'The post-deployment-only retry SQLCMD semantics differ from the approved initial script.'
    }
    Invoke-LocalSanitizedScript -Path $retryScriptPath
    $retrySeedCount = (
        Invoke-Sqlcmd @seedQueryArguments -Query @'
SELECT COUNT_BIG(*) AS [SeedCount]
FROM [app].[FeatureFlag]
WHERE [FlagName] = N'database-cicd-ready';
'@
    ).SeedCount
    if ($retrySeedCount -ne 1) {
        throw 'The post-deployment-only retry script did not restore seed data.'
    }
    Write-Information `
        'SqlPackage schema-success/postdeploy-failure recovery and exact-script execution passed.' `
        -InformationAction Continue

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
    if (Test-Path $exactScriptTestPath) {
        Remove-Item -Path $exactScriptTestPath -Recurse -Force
    }
}
