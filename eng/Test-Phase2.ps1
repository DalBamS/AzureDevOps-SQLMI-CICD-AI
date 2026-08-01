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

function Write-TestDeploymentManifest {
    param(
        [Parameter(Mandatory)][string]$ReviewPath,
        [Parameter(Mandatory)][string]$DacpacPath,
        [Parameter(Mandatory)][string[]]$DatabaseNames,
        [Parameter(Mandatory)][bool]$ValidateAllDatabasePlans
    )

    $representative = $DatabaseNames[0]
    $postDeployment = Get-DacFxPostDeploymentPayload -Path (Join-Path $ReviewPath 'deploy.sql')
    $postDeploymentSemantics = Get-DacFxPostDeploymentSemantic `
        -Path (Join-Path $ReviewPath 'deploy.sql') `
        -TargetDatabase $representative
    $artifactDefinitions = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in @(
        @('representativeReport', 'deploy-report.xml'),
        @('representativeScript', 'deploy.sql'),
        @('representativePolicy', 'deployment-script-policy.md')
    )) {
        $artifactDefinitions.Add([pscustomobject]@{
            Kind = $definition[0]
            Database = $representative
            Path = $definition[1]
        })
    }
    if ($ValidateAllDatabasePlans) {
        foreach ($database in $DatabaseNames) {
            foreach ($definition in @(
                @('databaseReport', "all-database-reports/$database.deploy-report.xml"),
                @('databaseScript', "all-database-scripts/$database.deploy.sql"),
                @('databasePolicy', "all-database-policy-reports/$database.deployment-script-policy.md")
            )) {
                $artifactDefinitions.Add([pscustomobject]@{
                    Kind = $definition[0]
                    Database = $database
                    Path = $definition[1]
                })
            }
        }
    }
    $artifacts = @(
        foreach ($definition in $artifactDefinitions) {
            $artifactPath = Join-Path $ReviewPath $definition.Path
            [ordered]@{
                kind = $definition.Kind
                database = $definition.Database
                path = $definition.Path
                sha256 = (Get-FileHash -Path $artifactPath -Algorithm SHA256).Hash
            }
        }
    )
    [ordered]@{
        manifestVersion = 5
        environment = 'fixture'
        representativeDatabase = $representative
        targetDatabases = $DatabaseNames
        allDatabasePlansValidated = $ValidateAllDatabasePlans
        allDatabaseScriptsGated = $ValidateAllDatabasePlans
        gatedDatabases = if ($ValidateAllDatabasePlans) { $DatabaseNames } else { @($representative) }
        driftPolicy = 'Warn'
        dacpacSha256 = (Get-FileHash -Path $DacpacPath -Algorithm SHA256).Hash
        postDeploymentContract = $postDeployment.Contract
        postDeploymentPayloadSha256 = $postDeployment.Sha256
        postDeploymentSemanticSha256 = $postDeploymentSemantics.SemanticPayloadSha256
        postDeploymentCanonicalVariableMapSha256 = $postDeploymentSemantics.CanonicalVariableMapSha256
        postDeploymentRuntimeVariables = $postDeploymentSemantics.RuntimeVariableContract
        artifacts = $artifacts
    } |
        ConvertTo-Json -Depth 8 |
        Set-Content -Path (Join-Path $ReviewPath 'target-databases.json') -Encoding utf8
}

function Get-TestDeploymentScript {
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [switch]$PostDeploymentOnly,
        [string]$PostDeploymentSql = "IF N'`$(Predicate)' = N'1=1' SELECT 1;"
    )

    $lines = @(
        '/*',
        "Deployment script for $DatabaseName",
        '*/',
        'GO',
        'SET ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, ARITHABORT, CONCAT_NULL_YIELDS_NULL, QUOTED_IDENTIFIER ON;',
        'SET NUMERIC_ROUNDABORT OFF;',
        'GO',
        ":setvar DatabaseName `"$DatabaseName`"",
        ":setvar DefaultFilePrefix `"$DatabaseName`"",
        ':setvar DefaultDataPath "/var/opt/mssql/data/"',
        ':setvar DefaultLogPath "/var/opt/mssql/data/"',
        ':setvar Predicate "1=1"',
        'GO',
        ':on error exit',
        'GO',
        ':setvar __IsSqlCmdEnabled "True"',
        'GO',
        'IF N''$(__IsSqlCmdEnabled)'' NOT LIKE N''True''',
        'BEGIN',
        '    PRINT N''SQLCMD mode is required.'';',
        '    SET NOEXEC ON;',
        'END',
        'GO',
        'USE [$(DatabaseName)];',
        'GO'
    )
    if (-not $PostDeploymentOnly) {
        $lines += 'SELECT 42;'
    }
    $lines += @(
        '-- SQLMI-CICD POSTDEPLOY START v1',
        $PostDeploymentSql,
        '-- SQLMI-CICD POSTDEPLOY END v1',
        'GO',
        'GO',
        'PRINT N''Update complete.'';',
        'GO'
    )
    return $lines -join "`n"
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
    $instanceWhatIfOutput = @(
        & (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') @instanceArguments *>&1
    )
    $instanceWhatIfLines = @($instanceWhatIfOutput | ForEach-Object { $_.ToString() })
    $instanceWhatIfText = $instanceWhatIfLines -join "`n"
    $instanceWhatIfHashes = @(
        [regex]::Matches(
            $instanceWhatIfText,
            '(?i)sanitized SHA-256:\s*(?<hash>[A-F0-9]{64})'
        ) |
            ForEach-Object { $_.Groups['hash'].Value }
    )
    Assert-True `
        -Condition (
            $instanceWhatIfLines.Count -eq 3 -and
            @($instanceWhatIfLines | Where-Object {
                $_ -notmatch (
                    "^Validated instance script \d/2 '\d{3}-[A-Za-z0-9-]+\.sql' " +
                    "for 'tcp:sqlmi\.example\.test,1433/master'; sanitized SHA-256: " +
                    '[A-F0-9]{64}$'
                ) -and
                $_ -cne 'Processed 2 instance object script(s) in filename order.'
            }).Count -eq 0 -and
            $instanceWhatIfHashes.Count -eq 2 -and
            $instanceWhatIfText -match '001-entra-login\.sql' -and
            $instanceWhatIfText -match '010-agent-job\.sql' -and
            $instanceWhatIfText -match 'tcp:sqlmi\.example\.test,1433/master' -and
            $instanceWhatIfText -notmatch 'fixture-token|example-deployer|CREATE LOGIN|sp_add_job'
        ) `
        -Message 'Instance WhatIf output must contain only file order, target, and sanitized hashes.'
    $instanceSqlCmdCallPath = Join-Path $temporaryPath 'instance-sqlcmd-calls.jsonl'
    $env:PHASE2_SQLCMD_MOCK_PATH = $instanceSqlCmdCallPath
    function global:Invoke-Sqlcmd {
        [CmdletBinding()]
        param(
            [string]$ServerInstance,
            [string]$Database,
            [string]$AccessToken,
            [string]$Query,
            [switch]$DisableCommands,
            [switch]$DisableVariables,
            [switch]$AbortOnError,
            [string]$Encrypt,
            [switch]$TrustServerCertificate,
            [int]$QueryTimeout,
            [int]$ConnectionTimeout
        )

        $queryHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Query))
        )
        [pscustomobject]@{
            ServerInstance = $ServerInstance
            Database = $Database
            AccessTokenLength = $AccessToken.Length
            QueryContainsCreateLogin = $Query -match 'CREATE LOGIN'
            QueryContainsAddJob = $Query -match 'sp_add_job'
            QueryContainsVariable = $Query -match '\$\('
            QuerySha256 = $queryHash
            DisableCommands = $DisableCommands.IsPresent
            DisableVariables = $DisableVariables.IsPresent
            AbortOnError = $AbortOnError.IsPresent
            Encrypt = $Encrypt
            TrustServerCertificate = $TrustServerCertificate.IsPresent
            QueryTimeout = $QueryTimeout
            ConnectionTimeout = $ConnectionTimeout
        } |
            ConvertTo-Json -Compress |
            Add-Content -Path $env:PHASE2_SQLCMD_MOCK_PATH -Encoding utf8
    }
    try {
        $executeInstanceArguments = @{} + $instanceArguments
        [void]$executeInstanceArguments.Remove('WhatIf')
        & (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') `
            @executeInstanceArguments `
            -Confirm:$false
    }
    finally {
        Remove-Item Function:\global:Invoke-Sqlcmd -Force
        Remove-Item Env:\PHASE2_SQLCMD_MOCK_PATH -ErrorAction SilentlyContinue
    }
    $instanceSqlCmdCalls = @(
        Get-Content -Path $instanceSqlCmdCallPath |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    Assert-True `
        -Condition (
            $instanceSqlCmdCalls.Count -eq 2 -and
            $instanceSqlCmdCalls[0].QueryContainsCreateLogin -and
            $instanceSqlCmdCalls[1].QueryContainsAddJob -and
            $instanceSqlCmdCalls[0].QuerySha256 -ceq $instanceWhatIfHashes[0] -and
            $instanceSqlCmdCalls[1].QuerySha256 -ceq $instanceWhatIfHashes[1] -and
            @($instanceSqlCmdCalls | Where-Object {
                -not $_.DisableCommands -or
                -not $_.DisableVariables -or
                -not $_.AbortOnError -or
                $_.TrustServerCertificate -or
                $_.QueryContainsVariable
            }).Count -eq 0
        ) `
        -Message 'Current instance examples must execute sanitized in-memory SQL in filename order with secondary parsing disabled.'
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
    $instanceFixturePath = Join-Path $temporaryPath 'instance-script-fixture'
    New-Item -ItemType Directory -Force -Path $instanceFixturePath | Out-Null
    foreach ($case in @(
        @{ Name = 'direct-include'; Sql = ':r C:\payload.sql'; Variables = @{} },
        @{ Name = 'direct-quit'; Sql = ':quit'; Variables = @{} },
        @{ Name = 'direct-ignore'; Sql = ':on error ignore'; Variables = @{} },
        @{ Name = 'direct-shell'; Sql = '!! whoami'; Variables = @{} },
        @{ Name = 'expanded-quit'; Sql = ':$(Command)'; Variables = @{ Command = 'quit' } },
        @{ Name = 'expanded-ignore'; Sql = ':on error $(Mode)'; Variables = @{ Mode = 'ignore' } },
        @{
            Name = 'embedded-setvar'
            Sql = ":setvar Command `":quit`"`n`$(Command)"
            Variables = @{ Command = 'benign' }
        }
    )) {
        Get-ChildItem -Path $instanceFixturePath -File | Remove-Item -Force
        @(
            '-- Idempotency: fixture precondition'
            'IF EXISTS (SELECT 1) PRINT N''fixture'';'
            $case.Sql
        ) | Set-Content `
            -Path (Join-Path $instanceFixturePath "001-$($case.Name).sql") `
            -Encoding utf8
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') `
                -ServerName 'sqlmi.example.test' `
                -AccessToken 'fixture-token' `
                -ScriptPath $instanceFixturePath `
                -SqlcmdVariables $case.Variables `
                -WhatIf
        } "Instance SQLCMD control case '$($case.Name)' must fail closed, including under WhatIf."
    }
    Get-ChildItem -Path $instanceFixturePath -File | Remove-Item -Force
    @(
        '-- Idempotency: fixture precondition'
        'IF EXISTS (SELECT 1) PRINT N''$(RequiredName)'';'
    ) | Set-Content `
        -Path (Join-Path $instanceFixturePath '001-extra-variable.sql') `
        -Encoding utf8
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') `
            -ServerName 'sqlmi.example.test' `
            -AccessToken 'fixture-token' `
            -ScriptPath $instanceFixturePath `
            -SqlcmdVariables @{ RequiredName = 'expected'; ExtraName = 'unexpected' } `
            -WhatIf
    } 'Instance deployment must reject extra SQLCMD variables, including under WhatIf.'
    Get-ChildItem -Path $instanceFixturePath -File | Remove-Item -Force
    @(
        '-- Idempotency: fixture precondition'
        'IF EXISTS (SELECT 1)'
        'BEGIN'
        '    PRINT N''`$(NotAVariable)'';'
        'END;'
    ) | Set-Content `
        -Path (Join-Path $instanceFixturePath '001-escaped-reference.sql') `
        -Encoding utf8
    & (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') `
        -ServerName 'sqlmi.example.test' `
        -AccessToken 'fixture-token' `
        -ScriptPath $instanceFixturePath `
        -SqlcmdVariables @{} `
        -WhatIf
    $instanceSafetyCases = @(
        @{
            Name = 'comment-only-guard'
            Sql = @'
-- Idempotency: fixture precondition
-- IF EXISTS (SELECT 1) PRINT N'not executable';
SELECT 1;
'@
        },
        @{
            Name = 'string-only-guard'
            Sql = @'
-- Idempotency: fixture precondition
PRINT N'IF NOT EXISTS (SELECT 1)';
'@
        },
        @{
            Name = 'comment-split-drop-login'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1) DROP/**/LOGIN [fixture_login];
'@
        },
        @{
            Name = 'drop-server-role'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1) DROP SERVER ROLE [fixture_role];
'@
        },
        @{
            Name = 'drop-credential'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1) DROP CREDENTIAL [fixture_credential];
'@
        },
        @{
            Name = 'constant-dynamic-drop'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1) EXEC(N'DR' + N'OP LOGIN [fixture_login];');
'@
        },
        @{
            Name = 'sp-executesql-dynamic-drop'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1) EXEC sys.sp_executesql N'DR' + N'OP CREDENTIAL [fixture_credential];';
'@
        },
        @{
            Name = 'variable-dynamic-drop'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    DECLARE @sql nvarchar(max) = N'DR' + N'OP LOGIN [fixture_login];';
    EXEC(@sql);
END;
'@
        },
        @{
            Name = 'static-delete-job'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1) EXEC [msdb].[dbo].[sp_delete_job] @job_name = N'fixture';
'@
        },
        @{
            Name = 'direct-truncate'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1) TRUNCATE TABLE [dbo].[Fixture];
'@
        },
        @{
            Name = 'unrelated-guard'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1 WHERE 1 = 0) PRINT N'not related';
CREATE LOGIN [fixture_login] FROM EXTERNAL PROVIDER;
'@
        },
        @{
            Name = 'bare-sp-executesql-dynamic-drop'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1) PRINT N'guard';
GO
sp_executesql N'DROP LOGIN [fixture_login];';
'@
        },
        @{
            Name = 'bare-delete-job'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1) PRINT N'guard';
GO
[msdb].[dbo].[sp_delete_job] @job_name = N'fixture';
'@
        },
        @{
            Name = 'guard-crosses-go'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1) PRINT N'guard'
GO
CREATE LOGIN [fixture_login] FROM EXTERNAL PROVIDER;
'@
        },
        @{
            Name = 'bare-add-job-outside-guard'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1) PRINT N'guard';
GO
[msdb].[dbo].[sp_add_job] @job_name = N'fixture';
'@
        },
        @{
            Name = 'guard-crosses-statement-without-semicolon'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1 WHERE 1 = 0)
    PRINT N'not related'
CREATE LOGIN [fixture_login] FROM EXTERNAL PROVIDER;
'@
        },
        @{
            Name = 'begin-transaction-case-end-confusion'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    BEGIN TRANSACTION;
END
CREATE LOGIN [fixture_login] FROM EXTERNAL PROVIDER;
SELECT CASE WHEN 1 = 1 THEN 1 END;
'@
        },
        @{
            Name = 'always-true-guard'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    CREATE LOGIN [fixture_login] FROM EXTERNAL PROVIDER;
END;
'@
        },
        @{
            Name = 'unrelated-login-catalog'
            Sql = @'
-- Idempotency: fixture precondition
IF NOT EXISTS (SELECT 1 FROM sys.credentials WHERE [name] = N'fixture_login')
BEGIN
    CREATE LOGIN [fixture_login] FROM EXTERNAL PROVIDER;
END;
'@
        },
        @{
            Name = 'mismatched-job-variable'
            Sql = @'
-- Idempotency: fixture precondition
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @OtherJobName)
BEGIN
    EXEC msdb.dbo.sp_add_job @job_name = @JobName;
END;
'@
        },
        @{
            Name = 'select-into'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE [name] = N'fixture')
BEGIN
    SELECT /* gap */ 1 AS [Id] INTO [dbo].[Copy];
END;
'@
        },
        @{
            Name = 'grant-permission'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE [name] = N'fixture')
BEGIN
    GRANT CONTROL SERVER TO [fixture_login];
END;
'@
        },
        @{
            Name = 'deny-permission'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE [name] = N'fixture')
BEGIN
    DENY CONNECT SQL TO [fixture_login];
END;
'@
        },
        @{
            Name = 'revoke-permission'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE [name] = N'fixture')
BEGIN
    REVOKE CONNECT SQL TO [fixture_login];
END;
'@
        },
        @{
            Name = 'dynamic-select-into'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC(N'SELECT 1 AS [Id] INTO [dbo].[Copy];');
END;
'@
        },
        @{
            Name = 'dynamic-grant'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC sys.sp_executesql N'GRANT CONTROL SERVER TO [fixture_login];';
END;
'@
        },
        @{
            Name = 'delete-jobstep-qualified'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC [msdb].[dbo].[sp_delete_jobstep] @job_name = N'fixture', @step_id = 1;
END;
'@
        },
        @{
            Name = 'delete-jobserver-quoted'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC "msdb"."dbo"."sp_delete_jobserver" @job_name = N'fixture';
END;
'@
        },
        @{
            Name = 'drop-login-omitted-schema'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC master..sp_droplogin N'fixture_login';
END;
'@
        },
        @{
            Name = 'remove-procedure-return-assignment'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC @returnCode = msdb.dbo.sp_remove_job N'fixture';
END;
'@
        },
        @{
            Name = 'detach-procedure'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC master.sys.sp_detach_db N'fixture';
END;
'@
        },
        @{
            Name = 'rename-procedure'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC sys.sp_rename N'dbo.Old', N'New';
END;
'@
        },
        @{
            Name = 'dynamic-delete-job'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC(N'EXEC msdb.dbo.sp_delete_job @job_name = N''fixture'';');
END;
'@
        },
        @{
            Name = 'nested-unrelated-login-catalog'
            Sql = @'
-- Idempotency: fixture precondition
IF NOT EXISTS (
    SELECT 1
    FROM sys.credentials
    WHERE [name] = N'fixture_login'
      AND EXISTS (SELECT 1 FROM sys.server_principals WHERE 1 = 0)
)
BEGIN
    CREATE LOGIN [fixture_login] FROM EXTERNAL PROVIDER;
END;
'@
        },
        @{
            Name = 'attacker-qualified-update-job'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'fixture';
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @JobName)
BEGIN
    EXEC EvilDb.attacker.sp_update_job @job_name = @JobName;
END;
'@
        },
        @{
            Name = 'procedure-argument-crosses-statement'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'fixture';
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @JobName)
BEGIN
    EXEC msdb.dbo.sp_update_job @job_name = @OtherJobName
    SELECT @job_name = @JobName;
END;
'@
        },
        @{
            Name = 'job-name-reassigned'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'approved';
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @JobName)
BEGIN
    SET @JobName = N'victim';
    EXEC msdb.dbo.sp_update_job @job_name = @JobName;
END;
'@
        },
        @{
            Name = 'job-id-unrelated-derivation'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'approved';
DECLARE @JobId uniqueidentifier;
DECLARE @StepName sysname = N'Health check';
SELECT @JobId = [job_id]
FROM msdb.dbo.sysjobs
WHERE [name] = N'victim';
IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobsteps
    WHERE [job_id] = @JobId AND [step_name] = @StepName
)
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @JobId,
        @step_name = @StepName;
END;
'@
        },
        @{
            Name = 'local-server-name-reassigned'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'approved';
DECLARE @JobId uniqueidentifier;
DECLARE @LocalServerName sysname = N'(LOCAL)';
SELECT @JobId = [job_id]
FROM msdb.dbo.sysjobs
WHERE [name] = @JobName;
IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobservers
    WHERE [job_id] = @JobId AND [server_id] = 0
)
BEGIN
    SET @LocalServerName = N'REMOTE';
    EXEC msdb.dbo.sp_add_jobserver
        @job_id = @JobId,
        @server_name = @LocalServerName;
END;
'@
        },
        @{
            Name = 'job-name-compound-assignment'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'approved';
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @JobName)
BEGIN
    SET @JobName += N'-victim';
    EXEC msdb.dbo.sp_update_job @job_name = @JobName;
END;
'@
        },
        @{
            Name = 'job-id-reassigned'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'approved';
DECLARE @JobId uniqueidentifier;
DECLARE @StepName sysname = N'Health check';
SELECT @JobId = [job_id]
FROM msdb.dbo.sysjobs
WHERE [name] = @JobName;
IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobsteps
    WHERE [job_id] = @JobId AND [step_name] = @StepName
)
BEGIN
    SET @JobId = NEWID();
    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @JobId,
        @step_name = @StepName;
END;
'@
        },
        @{
            Name = 'step-id-reassigned'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'approved';
DECLARE @JobId uniqueidentifier;
DECLARE @StepId int;
DECLARE @StepName sysname = N'Health check';
SELECT @JobId = [job_id] FROM msdb.dbo.sysjobs WHERE [name] = @JobName;
SELECT @StepId = [step_id]
FROM msdb.dbo.sysjobsteps
WHERE [job_id] = @JobId AND [step_name] = @StepName;
IF EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobsteps
    WHERE [job_id] = @JobId AND [step_name] = @StepName
)
BEGIN
    SET @StepId += 1;
    EXEC msdb.dbo.sp_update_jobstep
        @job_id = @JobId,
        @step_id = @StepId,
        @step_name = @StepName;
END;
'@
        },
        @{
            Name = 'create-login-reversed-polarity'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (
    SELECT 1 FROM sys.server_principals WHERE [name] = N'fixture_login'
)
BEGIN
    CREATE LOGIN [fixture_login] FROM EXTERNAL PROVIDER;
END;
'@
        },
        @{
            Name = 'add-job-reversed-polarity'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'fixture';
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @JobName)
BEGIN
    EXEC msdb.dbo.sp_add_job @job_name = @JobName;
END;
'@
        },
        @{
            Name = 'update-job-reversed-polarity'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'fixture';
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @JobName)
BEGIN
    EXEC msdb.dbo.sp_update_job @job_name = @JobName;
END;
'@
        },
        @{
            Name = 'quoted-identifier-fakes-id-flow'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'approved';
DECLARE @StepName sysname = N'Health check';
DECLARE @JobId AS uniqueidentifier = '11111111-1111-1111-1111-111111111111';
SELECT 1 AS "DECLARE @JobId uniqueidentifier;";
SELECT 1 AS "SELECT @JobId = job_id FROM msdb.dbo.sysjobs WHERE name = @JobName;";
IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobsteps
    WHERE [job_id] = @JobId AND [step_name] = @StepName
)
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @JobId,
        @step_name = @StepName;
END;
'@
        },
        @{
            Name = 'select-top-reassigns-job-id'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'approved';
DECLARE @StepName sysname = N'Health check';
DECLARE @JobId uniqueidentifier;
SELECT @JobId = [job_id]
FROM msdb.dbo.sysjobs
WHERE [name] = @JobName;
IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobsteps
    WHERE [job_id] = @JobId AND [step_name] = @StepName
)
BEGIN
    SELECT TOP (1) @JobId = [job_id]
    FROM msdb.dbo.sysjobs
    WHERE [name] = N'victim';
    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @JobId,
        @step_name = @StepName;
END;
'@
        },
        @{
            Name = 'mismatched-login-name'
            Sql = @'
-- Idempotency: fixture precondition
IF NOT EXISTS (
    SELECT 1 FROM sys.server_principals WHERE [name] = N'approved_login'
)
BEGIN
    CREATE LOGIN [other_login] FROM EXTERNAL PROVIDER;
END;
'@
        },
        @{
            Name = 'add-job-in-existing-branch'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'fixture';
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @JobName)
BEGIN
    EXEC msdb.dbo.sp_add_job @job_name = @JobName;
END;
'@
        },
        @{
            Name = 'update-job-in-missing-branch'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'fixture';
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @JobName)
BEGIN
    EXEC msdb.dbo.sp_update_job @job_name = @JobName;
END;
'@
        },
        @{
            Name = 'nested-inner-unrelated-guard'
            Sql = @'
-- Idempotency: fixture precondition
IF NOT EXISTS (
    SELECT 1 FROM sys.server_principals WHERE [name] = N'fixture_login'
)
BEGIN
    IF EXISTS (SELECT 1)
    BEGIN
        CREATE LOGIN [fixture_login] FROM EXTERNAL PROVIDER;
    END;
END;
'@
        },
        @{
            Name = 'mismatched-step-name'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'fixture';
DECLARE @JobId uniqueidentifier;
DECLARE @StepName sysname = N'Health check';
DECLARE @OtherStepName sysname = N'Other';
SELECT @JobId = [job_id] FROM msdb.dbo.sysjobs WHERE [name] = @JobName;
IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobsteps
    WHERE [job_id] = @JobId AND [step_name] = @StepName
)
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @JobId,
        @step_name = @OtherStepName;
END;
'@
        },
        @{
            Name = 'mismatched-jobserver-target'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'fixture';
DECLARE @JobId uniqueidentifier;
DECLARE @LocalServerName sysname = N'(LOCAL)';
SELECT @JobId = [job_id] FROM msdb.dbo.sysjobs WHERE [name] = @JobName;
IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobservers
    WHERE [job_id] = @JobId AND [server_id] = 1
)
BEGIN
    EXEC msdb.dbo.sp_add_jobserver
        @job_id = @JobId,
        @server_name = @LocalServerName;
END;
'@
        },
        @{
            Name = 'bare-add-job-inside-correlated-guard'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobName sysname = N'fixture';
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE [name] = @JobName)
BEGIN
    msdb.dbo.sp_add_job @job_name = @JobName;
END;
'@
        },
        @{
            Name = 'bare-destructive-procedure-inside-guard'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    msdb.dbo.sp_delete_jobstep @job_name = N'fixture', @step_id = 1;
END;
'@
        },
        @{
            Name = 'revoke-family-procedure'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC [msdb].[dbo].[sp_revoke_proxy_from_subsystem] @proxy_name = N'fixture';
END;
'@
        },
        @{
            Name = 'bare-unsupported-system-procedure'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    msdb.dbo.sp_start_job @job_name = N'fixture';
END;
'@
        },
        @{
            Name = 'dynamic-bare-unsupported-system-procedure'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC(N'msdb.dbo.sp_start_job @job_name = N''fixture'';');
END;
'@
        },
        @{
            Name = 'static-disable-trigger'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    DISABLE TRIGGER ALL ON DATABASE;
END;
'@
        },
        @{
            Name = 'static-enable-trigger'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    ENABLE TRIGGER ALL ON DATABASE;
END;
'@
        },
        @{
            Name = 'static-dbcc-checkident'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    DBCC CHECKIDENT (N'dbo.Fixture', RESEED, 0);
END;
'@
        },
        @{
            Name = 'static-backup'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    BACKUP DATABASE [master] TO DISK = N'fixture.bak';
END;
'@
        },
        @{
            Name = 'static-restore'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    RESTORE DATABASE [Fixture] FROM DISK = N'fixture.bak';
END;
'@
        },
        @{
            Name = 'static-kill'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    KILL 53;
END;
'@
        },
        @{
            Name = 'static-shutdown'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    SHUTDOWN WITH NOWAIT;
END;
'@
        },
        @{
            Name = 'static-bulk-insert'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    BULK INSERT [dbo].[Fixture] FROM N'fixture.csv';
END;
'@
        },
        @{
            Name = 'static-checkpoint'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    CHECKPOINT;
END;
'@
        },
        @{
            Name = 'static-reconfigure'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    RECONFIGURE;
END;
'@
        },
        @{
            Name = 'static-waitfor'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    WAITFOR DELAY '00:00:01';
END;
'@
        },
        @{
            Name = 'dynamic-dbcc-checkident'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC(N'DBCC CHECKIDENT (N''dbo.Fixture'', RESEED, 0);');
END;
'@
        },
        @{
            Name = 'static-select-variable-assignment'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @OwnerLoginName sysname = N'approved';
IF EXISTS (SELECT 1)
BEGIN
    SELECT @OwnerLoginName = N'other';
END;
'@
        },
        @{
            Name = 'dynamic-select-variable-assignment'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC(N'SELECT @JobId = NEWID();');
END;
'@
        },
        @{
            Name = 'dynamic-select-output-argument'
            Sql = @'
-- Idempotency: fixture precondition
DECLARE @JobId uniqueidentifier;
IF EXISTS (SELECT 1)
BEGIN
    EXEC sys.sp_executesql
        N'SELECT @Value = NEWID();',
        N'@Value uniqueidentifier OUTPUT',
        @Value = @JobId OUTPUT;
END;
'@
        },
        @{
            Name = 'direct-next-value-for'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    SELECT NEXT /* lexical gap */ VALUE
        FOR [dbo].[FixtureSequence] AS [SequenceValue];
END;
'@
        },
        @{
            Name = 'dynamic-next-value-for'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC(N'SELECT NEXT /* lexical gap */ VALUE FOR [dbo].[FixtureSequence];');
END;
'@
        },
        @{
            Name = 'dynamic-multiple-select-next-value'
            Sql = @'
-- Idempotency: fixture precondition
IF EXISTS (SELECT 1)
BEGIN
    EXEC(N'SELECT 1; SELECT NEXT VALUE FOR "dbo"."FixtureSequence";');
END;
'@
        }
    )
    foreach ($case in $instanceSafetyCases) {
        Get-ChildItem -Path $instanceFixturePath -File | Remove-Item -Force
        Set-Content `
            -Path (Join-Path $instanceFixturePath "001-$($case.Name).sql") `
            -Value $case.Sql `
            -Encoding utf8
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') `
                -ServerName 'sqlmi.example.test' `
                -AccessToken 'fixture-token' `
                -ScriptPath $instanceFixturePath `
                -SqlcmdVariables @{} `
                -WhatIf
        } "Instance safety case '$($case.Name)' must fail closed."
    }
    $blockedSqlCmdCallPath = Join-Path $temporaryPath 'blocked-instance-sqlcmd-calls.log'
    $env:PHASE2_BLOCKED_SQLCMD_MOCK_PATH = $blockedSqlCmdCallPath
    function global:Invoke-Sqlcmd {
        [CmdletBinding()]
        param(
            [string]$ServerInstance,
            [string]$Database,
            [string]$AccessToken,
            [string]$Query,
            [switch]$DisableCommands,
            [switch]$DisableVariables,
            [switch]$AbortOnError,
            [string]$Encrypt,
            [switch]$TrustServerCertificate,
            [int]$QueryTimeout,
            [int]$ConnectionTimeout
        )

        $null = @(
            $ServerInstance,
            $Database,
            $AccessToken,
            $DisableCommands,
            $DisableVariables,
            $AbortOnError,
            $Encrypt,
            $TrustServerCertificate,
            $QueryTimeout,
            $ConnectionTimeout
        )
        Add-Content -Path $env:PHASE2_BLOCKED_SQLCMD_MOCK_PATH -Value $Query -Encoding utf8
    }
    try {
        foreach ($case in $instanceSafetyCases) {
            Get-ChildItem -Path $instanceFixturePath -File | Remove-Item -Force
            Set-Content `
                -Path (Join-Path $instanceFixturePath "001-$($case.Name).sql") `
                -Value $case.Sql `
                -Encoding utf8
            Assert-Throws {
                & (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') `
                    -ServerName 'sqlmi.example.test' `
                    -AccessToken 'fixture-token' `
                    -ScriptPath $instanceFixturePath `
                    -SqlcmdVariables @{} `
                    -Confirm:$false
            } "Instance safety case '$($case.Name)' must fail before SQL execution."
        }
    }
    finally {
        Remove-Item Function:\global:Invoke-Sqlcmd -Force
        Remove-Item Env:\PHASE2_BLOCKED_SQLCMD_MOCK_PATH -ErrorAction SilentlyContinue
    }
    Assert-True `
        -Condition (-not (Test-Path $blockedSqlCmdCallPath)) `
        -Message 'Rejected instance scripts must never reach Invoke-Sqlcmd.'
    Get-ChildItem -Path $instanceFixturePath -File | Remove-Item -Force
    @'
-- Idempotency: comments do not replace the executable guard.
/* IF EXISTS (SELECT 1) DROP LOGIN [comment_only]; */
IF NOT EXISTS (
    SELECT 1
    FROM sys.server_principals
    WHERE [name] = N'fixture_login'
)
BEGIN
    PRINT N'DROP LOGIN in a string is not executable.';
    SELECT 1 AS [DROP], 2 AS "TRUNCATE";
    EXEC(N'SELECT 1 AS [CREATE];');
END;
'@ | Set-Content `
        -Path (Join-Path $instanceFixturePath '001-valid-comments.sql') `
        -Encoding utf8
    & (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') `
        -ServerName 'sqlmi.example.test' `
        -AccessToken 'fixture-token' `
        -ScriptPath $instanceFixturePath `
        -SqlcmdVariables @{} `
        -WhatIf
    Get-ChildItem -Path $instanceFixturePath -File | Remove-Item -Force
    @'
-- Idempotency: only the innermost correlated guard authorizes the supported mutation.
DECLARE @JobName sysname = N'fixture';
IF EXISTS (SELECT 1)
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM msdb.dbo.sysjobs
        WHERE [name] = @JobName
    )
    BEGIN
        EXEC msdb.dbo.sp_add_job @job_name = @JobName;
    END;
END;
PRINT N'SELECT 1 INTO dbo.Copy; GRANT DENY REVOKE';
SELECT 1 AS [INTO], 2 AS [GRANT], 3 AS "REVOKE", 4 AS [NEXT VALUE FOR];
'@ | Set-Content `
        -Path (Join-Path $instanceFixturePath '001-nested-correlated.sql') `
        -Encoding utf8
    & (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') `
        -ServerName 'sqlmi.example.test' `
        -AccessToken 'fixture-token' `
        -ScriptPath $instanceFixturePath `
        -SqlcmdVariables @{} `
        -WhatIf

    & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
        -ScriptPath (Join-Path $fixtures 'deployment-safe.sql') `
        -ReportPath (Join-Path $temporaryPath 'safe-report.md')
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
            -ScriptPath (Join-Path $fixtures 'deployment-destructive.sql') `
            -ReportPath (Join-Path $temporaryPath 'destructive-report.md')
    } 'The Phase 1 destructive deployment regression fixture should fail.'
    $dynamicPolicyCases = @(
        @{ Name = 'direct-exec'; Sql = "EXEC(N'DROP TABLE [dbo].[Danger];');" },
        @{ Name = 'execute-concat'; Sql = "EXECUTE ( N'DR' + N'OP TABLE [dbo].[Danger];' );" },
        @{ Name = 'sp-executesql-concat'; Sql = "EXEC sys.sp_executesql N'DROP ' + N'TABLE [dbo].[Danger];';" },
        @{ Name = 'quoted-sp-executesql'; Sql = "EXEC `"sys`".`"sp_executesql`" N'DROP TABLE [dbo].[Danger];';" },
        @{ Name = 'qualified-quoted-sp-executesql'; Sql = "EXEC [AppDb].`"sys`".[sp_executesql] N'DROP TABLE [dbo].[Danger];';" },
        @{ Name = 'quoted-sp-executesql-variable'; Sql = 'EXEC [sys]."sp_executesql" @sql;' },
        @{ Name = 'variable-exec'; Sql = "DECLARE @sql nvarchar(max) = N'DROP TABLE [dbo].[Danger];'; EXEC(@sql);" },
        @{ Name = 'function-expression'; Sql = "EXEC sp_executesql REPLACE(N'DRXP TABLE [dbo].[Danger];', N'X', N'O');" },
        @{ Name = 'comment-concat'; Sql = "EXEC (N'DR'/* split */ + N'OP TABLE [dbo].[O''Brien];');" },
        @{ Name = 'nested-dynamic'; Sql = "EXEC(N'EXEC(N''DROP TABLE [dbo].[Danger];'')');" },
        @{ Name = 'database-qualified'; Sql = "EXEC AppDb.sys.sp_executesql N'DROP TABLE [dbo].[Danger];';" },
        @{ Name = 'omitted-schema-sp-executesql'; Sql = "EXEC master..sp_executesql N'DROP TABLE [dbo].[Danger];';" },
        @{ Name = 'quoted-omitted-schema-sp-executesql'; Sql = "EXEC [master]..[sp_executesql] N'DROP TABLE [dbo].[Danger];';" },
        @{ Name = 'leading-omitted-sp-executesql'; Sql = "EXEC .sys.sp_executesql N'DROP TABLE [dbo].[Danger];';" },
        @{ Name = 'double-leading-omitted-sp-executesql'; Sql = "EXEC ..sp_executesql N'DROP TABLE [dbo].[Danger];';" },
        @{ Name = 'double-middle-omitted-sp-executesql'; Sql = "EXEC server...sp_executesql N'DROP TABLE [dbo].[Danger];';" },
        @{ Name = 'four-part-omitted-sp-executesql'; Sql = "EXEC [server].[master]..`"sp_executesql`" N'DROP TABLE [dbo].[Danger];';" },
        @{ Name = 'quoted-sp-rename'; Sql = 'EXEC "sys"."sp_rename" N''dbo.OldName'', N''NewName'';' },
        @{ Name = 'qualified-quoted-sp-rename'; Sql = 'EXEC [AppDb]."sys".[sp_rename] N''dbo.OldName'', N''NewName'';' },
        @{ Name = 'omitted-schema-sp-rename'; Sql = 'EXEC master..sp_rename N''dbo.OldName'', N''NewName'';' },
        @{ Name = 'malformed-trailing-dot'; Sql = 'EXEC master..benignProc.;' },
        @{ Name = 'malformed-five-part'; Sql = 'EXEC server.database.schema.extra.benignProc @p=1;' },
        @{ Name = 'malformed-missing-final'; Sql = 'EXEC master..;' },
        @{ Name = 'dynamic-create-unique-index'; Sql = "EXEC(N'CREATE UNIQUE INDEX [IX_T] ON [dbo].[T]([Id]);');" },
        @{ Name = 'dynamic-create-clustered-index'; Sql = "EXEC(N'CREATE CLUSTERED INDEX [IX_T] ON [dbo].[T]([Id]);');" },
        @{ Name = 'dynamic-create-unique-nonclustered-index'; Sql = "EXEC(N'CREATE UNIQUE NONCLUSTERED INDEX [IX_T] ON [dbo].[T]([Id]);');" },
        @{ Name = 'dynamic-create-columnstore-index'; Sql = "EXEC(N'CREATE COLUMNSTORE INDEX [IX_T] ON [dbo].[T]([Id]);');" },
        @{ Name = 'dynamic-create-modifier-comments'; Sql = "EXEC(N'CREATE /* review */ UNIQUE`nNONCLUSTERED /* gap */ INDEX [IX_T] ON [dbo].[T]([Id]);');" },
        @{ Name = 'dynamic-create-unknown-modifier'; Sql = "EXEC(N'CREATE UNIQUE HASH INDEX [IX_T] ON [dbo].[T]([Id]);');" },
        @{ Name = 'dynamic-create-xml-index'; Sql = "EXEC(N'CREATE XML INDEX [IX_T] ON [dbo].[T]([Payload]);');" },
        @{ Name = 'dynamic-create-spatial-index'; Sql = "EXEC(N'CREATE SPATIAL INDEX [IX_T] ON [dbo].[T]([Shape]);');" },
        @{ Name = 'dynamic-create-partition-function'; Sql = "EXEC(N'CREATE PARTITION FUNCTION [PF](int) AS RANGE LEFT FOR VALUES (1);');" },
        @{ Name = 'dynamic-drop-certificate'; Sql = "EXEC(N'DROP CERTIFICATE [FixtureCertificate];');" },
        @{ Name = 'dynamic-create-statistics'; Sql = "EXEC(N'CREATE STATISTICS [ST_T] ON [dbo].[T]([Id]);');" },
        @{ Name = 'dynamic-alter-authorization'; Sql = "EXEC(N'ALTER AUTHORIZATION ON DATABASE::[AppDb] TO [dbo];');" },
        @{ Name = 'dynamic-leading-set-use'; Sql = "EXEC(N'/* setup */ SET NOCOUNT ON; USE [AppDb]; CREATE STATISTICS [ST_T] ON [dbo].[T]([Id]);');" },
        @{ Name = 'dynamic-second-statement-ddl'; Sql = "EXEC(N'SELECT 1; DROP CERTIFICATE [FixtureCertificate];');" },
        @{ Name = 'dynamic-cte-then-ddl'; Sql = "EXEC(N';WITH [c] AS (SELECT 1 AS [Id]) SELECT [Id] FROM [c]; CREATE STATISTICS [ST_T] ON [dbo].[T]([Id]);');" },
        @{ Name = 'bare-sp-executesql'; Sql = "sp_executesql N'DROP TABLE [dbo].[Danger];';" },
        @{ Name = 'bare-quoted-sp-executesql'; Sql = "[sys].[sp_executesql] N'CREATE STATISTICS [ST_T] ON [dbo].[T]([Id]);';" }
    )
    foreach ($case in $dynamicPolicyCases) {
        $casePath = Join-Path $temporaryPath "$($case.Name).sql"
        $caseReportPath = Join-Path $temporaryPath "$($case.Name).md"
        Set-Content -Path $casePath -Value $case.Sql -Encoding utf8
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
                -ScriptPath $casePath `
                -ReportPath $caseReportPath
        } "Dynamic SQL policy case '$($case.Name)' must fail closed."
        Assert-True `
            -Condition (Test-Path $caseReportPath -PathType Leaf) `
            -Message "Dynamic SQL policy case '$($case.Name)' must produce a policy report."
        Assert-True `
            -Condition ((Get-Content -Path $caseReportPath -Raw) -match 'DEPLOY00[789]') `
            -Message "Dynamic SQL policy case '$($case.Name)' must fail through a dynamic execution rule."
    }
    foreach ($case in @(
        @{ Name = 'static-procedure'; Sql = 'EXEC dbo.StoredProcedure @p = 1;' },
        @{ Name = 'static-return-procedure'; Sql = 'EXEC @rc = dbo.StoredProcedure @p = 1;' },
        @{ Name = 'constant-select'; Sql = "EXEC(N'SELECT 1;');" },
        @{ Name = 'constant-select-ddl-text'; Sql = "EXEC(N'SELECT N''CREATE UNIQUE INDEX [IX_T] ON [dbo].[T]([Id])'';');" },
        @{ Name = 'constant-select-ddl-identifier'; Sql = "EXEC(N'SELECT 1 AS [DROP], 2 AS `"CREATE`";');" },
        @{ Name = 'named-constant-select'; Sql = "EXEC sys.sp_executesql @stmt = N'SELECT 1;';" },
        @{ Name = 'constant-parameterized-update'; Sql = "EXEC sys.sp_executesql N'UPDATE [dbo].[T] SET [Value] = @Value WHERE [Id] = @Id;', N'@Value int, @Id int', @Value=2, @Id=1;" },
        @{ Name = 'constant-leading-set-select'; Sql = "EXEC(N'SET NOCOUNT ON; USE [AppDb]; SELECT 1;');" },
        @{ Name = 'bare-sp-executesql-select'; Sql = "sp_executesql N'SELECT 1;';" },
        @{ Name = 'nested-comment'; Sql = '/* outer /* nested */ EXEC(N''DROP TABLE dbo.Hidden''); */ SELECT 1;' },
        @{ Name = 'bracket-apostrophe'; Sql = 'CREATE TABLE [dbo].[O''Brien] ([Id] int NOT NULL);' },
        @{ Name = 'quoted-user-procedure'; Sql = 'EXEC "dbo"."sp_executesql_safe" @p = 1;' },
        @{ Name = 'omitted-schema-user-procedure'; Sql = 'EXEC master..benignProc @p = 1;' },
        @{ Name = 'quoted-omitted-user-procedure'; Sql = 'EXEC [master]..[benignProc] @p = 1;' },
        @{ Name = 'four-part-omitted-user-procedure'; Sql = 'EXEC server.master..benignProc @p = 1;' },
        @{ Name = 'sqlcmd-dacfx-variables'; Sql = @'
:setvar DatabaseName "AppDb"
:setvar DefaultFilePrefix "AppDb"
:setvar DefaultDataPath "/var/opt/mssql/data/"
:setvar DefaultLogPath "/var/opt/mssql/data/"
USE [$(DatabaseName)];
SELECT N'$(DefaultDataPath)', N'$(DefaultLogPath)', N'$(DefaultFilePrefix)';
'@ },
        @{ Name = 'sqlcmd-escaped-literal'; Sql = @'
:setvar DatabaseName "AppDb"
PRINT N'`$(NotAVariable)';
'@ },
        @{ Name = 'alter-keywords-in-string'; Sql = "SELECT N'ALTER TABLE dbo.T DROP COLUMN C;';" },
        @{ Name = 'alter-keywords-in-identifier'; Sql = 'CREATE TABLE [ALTER TABLE DROP COLUMN] ([Id] int);' },
        @{ Name = 'alter-keywords-in-quoted-identifier'; Sql = 'CREATE TABLE "ALTER TABLE DROP COLUMN" ("Id" int);' },
        @{ Name = 'alter-keywords-in-comments'; Sql = '/* ALTER TABLE dbo.T /* nested */ DROP COLUMN C; */ SELECT 1;' }
        @{ Name = 'go-inside-multiline-string'; Sql = "PRINT N'first`nGO`nDROP TABLE [dbo].[StringOnly]';`nSELECT 1;" }
        @{ Name = 'go-inside-block-comment'; Sql = "/* first`nGO`nDROP TABLE [dbo].[CommentOnly];`n*/`nSELECT 1;" }
        @{ Name = 'go-inside-nested-comment'; Sql = "/* outer /* nested`nGO`nDROP TABLE [dbo].[CommentOnly];`n*/ outer */`nSELECT 1;" }
        @{ Name = 'go-inside-bracket-identifier'; Sql = "SELECT 1 AS [first`nGO`nDROP TABLE];" }
        @{ Name = 'go-inside-quoted-identifier'; Sql = "SELECT 1 AS `"first`nGO`nDROP TABLE`";" }
        @{ Name = 'go-after-line-comment-text'; Sql = "SELECT 1; -- GO`nSELECT 2;" }
        @{ Name = 'line-comment-before-go-text'; Sql = "-- GO`nSELECT 1;" }
        @{ Name = 'go-trailing-comment'; Sql = "SELECT 1;`nGO 1 -- supported trailing line comment`nSELECT 2;" }
    )) {
        $casePath = Join-Path $temporaryPath "$($case.Name).sql"
        Set-Content -Path $casePath -Value $case.Sql -Encoding utf8
        & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
            -ScriptPath $casePath `
            -ReportPath (Join-Path $temporaryPath "$($case.Name).md")
    }
    Assert-True `
        -Condition (
            (Get-Content -Path (Join-Path $temporaryPath 'go-trailing-comment.md') -Raw) -match
                'GO-delimited batches: 2'
        ) `
        -Message 'A code-context GO count with a trailing line comment must split exactly two batches.'
    $acceptedGoSeparators = @(
        @{ Name = 'go-zero'; Line = 'GO 0' },
        @{ Name = 'go-double-zero'; Line = 'GO 00' },
        @{ Name = 'go-leading-zero'; Line = 'GO 01' },
        @{ Name = 'go-int32-max'; Line = 'GO 2147483647' },
        @{ Name = 'go-mixed-case-whitespace'; Line = "`t gO`t00042 `t-- managed parser comment" }
    )
    foreach ($case in $acceptedGoSeparators) {
        $safePath = Join-Path $temporaryPath "$($case.Name)-safe.sql"
        $safeReportPath = Join-Path $temporaryPath "$($case.Name)-safe.md"
        "SELECT 1;`r`n$($case.Line)`r`nSELECT 2;" |
            Set-Content -Path $safePath -Encoding utf8 -NoNewline
        & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
            -ScriptPath $safePath `
            -ReportPath $safeReportPath
        Assert-True `
            -Condition (
                (Get-Content -Path $safeReportPath -Raw) -match
                    'GO-delimited batches: 2'
            ) `
            -Message "Managed GO grammar case '$($case.Name)' must split two analysis batches."

        $unsafePath = Join-Path $temporaryPath "$($case.Name)-unsafe.sql"
        "SELECT 1;`r`n$($case.Line)`r`nsp_executesql N'DROP TABLE [dbo].[Danger];';" |
            Set-Content -Path $unsafePath -Encoding utf8 -NoNewline
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
                -ScriptPath $unsafePath `
                -ReportPath (Join-Path $temporaryPath "$($case.Name)-unsafe.md")
        } "Bare dynamic DDL after managed GO grammar case '$($case.Name)' must be analyzed."
    }
    $attachedGoPath = Join-Path $temporaryPath 'go-attached-count.sql'
    $attachedGoReport = Join-Path $temporaryPath 'go-attached-count.md'
    "SELECT 1;`nGO1`nSELECT 2;" |
        Set-Content -Path $attachedGoPath -Encoding utf8 -NoNewline
    & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
        -ScriptPath $attachedGoPath `
        -ReportPath $attachedGoReport
    Assert-True `
        -Condition (
            (Get-Content -Path $attachedGoReport -Raw) -match
                'GO-delimited batches: 1'
        ) `
        -Message 'GO1 is an ordinary SQL token, not a managed GO separator candidate.'
    foreach ($case in @(
        @{ Name = 'go-int32-overflow'; Line = 'GO 2147483648' },
        @{ Name = 'go-numeric-overflow'; Line = 'GO 999999999999999999999999999999999999' },
        @{ Name = 'go-negative'; Line = 'GO -1' },
        @{ Name = 'go-plus'; Line = 'GO +1' },
        @{ Name = 'go-decimal'; Line = 'GO 1.5' },
        @{ Name = 'go-alpha-suffix'; Line = 'GO 1x' },
        @{ Name = 'go-block-comment-suffix'; Line = 'GO 1 /* not a supported suffix */' },
        @{ Name = 'go-extra-token'; Line = 'GO 1 SELECT 2' }
    )) {
        $casePath = Join-Path $temporaryPath "$($case.Name).sql"
        "SELECT 1;`n$($case.Line)`nSELECT 2;" |
            Set-Content -Path $casePath -Encoding utf8 -NoNewline
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
                -ScriptPath $casePath `
                -ReportPath (Join-Path $temporaryPath "$($case.Name).md")
        } "Invalid GO count case '$($case.Name)' must fail before execution."
    }
    $dacFxMultilinePath = Join-Path $temporaryPath 'dacfx-multiline.sql'
    $dacFxMultilineReportPath = Join-Path $temporaryPath 'dacfx-multiline.md'
    $dacFxMultilineScript = Get-TestDeploymentScript `
        -DatabaseName 'DacFxFixture' `
        -PostDeploymentSql @'
PRINT N'DacFx can emit payload text across physical lines:
GO
DROP TABLE [dbo].[StringOnly];';
SELECT 1 AS [StillCode];
'@
    Set-Content `
        -Path $dacFxMultilinePath `
        -Value ($dacFxMultilineScript.Replace("`n", "`r`n")) `
        -Encoding utf8 `
        -NoNewline
    & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
        -ScriptPath $dacFxMultilinePath `
        -ReportPath $dacFxMultilineReportPath
    Assert-True `
        -Condition (
            (Get-Content -Path $dacFxMultilineReportPath -Raw) -match
                '(?m)^- Errors: 0\r?$'
        ) `
        -Message 'A CRLF DacFx script must not split GO text inside a multiline string.'
    $dacFxExecutableDropPath = Join-Path $temporaryPath 'dacfx-executable-drop.sql'
    Set-Content `
        -Path $dacFxExecutableDropPath `
        -Value (
            $dacFxMultilineScript.Replace(
                "SELECT 1 AS [StillCode];",
                "SELECT 1 AS [StillCode];`nGO`nDROP TABLE [dbo].[ExecutableDrop];"
            ).Replace("`n", "`r`n")
        ) `
        -Encoding utf8 `
        -NoNewline
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
            -ScriptPath $dacFxExecutableDropPath `
            -ReportPath (Join-Path $temporaryPath 'dacfx-executable-drop.md')
    } 'A real GO after a multiline DacFx payload must expose destructive SQL to policy checks.'
    $sqlCmdAndAlterPolicyCases = @(
        @{ Name = 'sqlcmd-direct-drop'; Sql = ":setvar ObjectType `"TABLE`"`nDROP `$(ObjectType) [dbo].[Danger];" },
        @{ Name = 'sqlcmd-dynamic-drop'; Sql = ":setvar Verb `"DROP`"`nEXEC(N'`$(Verb) TABLE [dbo].[Danger];');" },
        @{ Name = 'sqlcmd-unresolved'; Sql = 'SELECT N''$(Missing)'';' },
        @{ Name = 'sqlcmd-invalid-reference'; Sql = 'SELECT N''$(Invalid-Name)'';' },
        @{ Name = 'sqlcmd-duplicate'; Sql = ":setvar Name `"One`"`n:setvar name `"Two`"`nSELECT 1;" },
        @{ Name = 'sqlcmd-malformed'; Sql = ":setvar Name unquoted`nSELECT 1;" },
        @{ Name = 'sqlcmd-nested-value'; Sql = ":setvar Name `"`$(Other)`"`nSELECT N'`$(Name)';" },
        @{ Name = 'sqlcmd-semicolon-value'; Sql = ":setvar Name `"value;DROP`"`nSELECT N'`$(Name)';" },
        @{ Name = 'sqlcmd-apostrophe-breakout'; Sql = ":setvar Name `"x' DELETE FROM dbo.T--`"`nSELECT N'`$(Name)';" },
        @{ Name = 'sqlcmd-bracket-breakout'; Sql = ":setvar Name `"x] DROP TABLE dbo.T`"`nSELECT N'`$(Name)';" },
        @{ Name = 'sqlcmd-line-comment-value'; Sql = ":setvar Name `"x--comment`"`nSELECT N'`$(Name)';" },
        @{ Name = 'sqlcmd-block-comment-open'; Sql = ":setvar Name `"x/*comment`"`nSELECT N'`$(Name)';" },
        @{ Name = 'sqlcmd-block-comment-close'; Sql = ":setvar Name `"x*/comment`"`nSELECT N'`$(Name)';" },
        @{ Name = 'sqlcmd-double-quote-breakout'; Sql = ":setvar Name `"x`" DROP TABLE dbo.T`"`nSELECT N'`$(Name)';" },
        @{ Name = 'sqlcmd-after-line-comment-block-opener'; Sql = "-- /*`n!! whoami`n*/`nSELECT 1;" },
        @{ Name = 'sqlcmd-after-line-comment-quote'; Sql = "-- '`n:quit`nSELECT 1;" },
        @{ Name = 'sqlcmd-after-line-comment-bracket'; Sql = "-- [`n:exit`nSELECT 1;" },
        @{ Name = 'sqlcmd-after-line-comment-double-quote'; Sql = "-- `"`n:connect tcp:other.example.test`nSELECT 1;" },
        @{ Name = 'sqlcmd-expanded-include'; Sql = ":setvar C `":r C:\payload.sql`"`n`$(C)" },
        @{ Name = 'sqlcmd-expanded-quit'; Sql = ":setvar C `":quit`"`n`$(C)" },
        @{ Name = 'sqlcmd-expanded-ignore'; Sql = ":setvar C `":on error ignore`"`n`$(C)" },
        @{ Name = 'sqlcmd-expanded-shell'; Sql = ":setvar C `"!! whoami`"`n`$(C)" },
        @{ Name = 'sqlcmd-expanded-leading-space'; Sql = ":setvar C `"   :QuIt`"`n`$(C)" },
        @{ Name = 'sqlcmd-expanded-concat-command'; Sql = ":setvar C `"quit`"`n:`$(C)" },
        @{ Name = 'sqlcmd-command-in-bracket-identifier'; Sql = "SELECT [first`n:quit`nlast];" },
        @{ Name = 'sqlcmd-command-in-quoted-identifier'; Sql = "SELECT `"first`n!! whoami`nlast`";" },
        @{ Name = 'alter-long-whitespace'; Sql = "ALTER TABLE [dbo].[T] $(' ' * 1001) DROP COLUMN [C];" },
        @{ Name = 'alter-very-long-whitespace'; Sql = "ALTER TABLE [dbo].[T] $(' ' * 10000) DROP CONSTRAINT [DF_T_C];" },
        @{ Name = 'alter-nested-comment'; Sql = "ALTER TABLE [dbo].[T] /* outer /* $('x' * 1500) */ outer */ DROP COLUMN [C];" },
        @{ Name = 'alter-line-comment'; Sql = "ALTER TABLE [dbo].[T] -- $('x' * 1500)`nDROP CONSTRAINT [DF_T_C];" },
        @{ Name = 'alter-second-statement'; Sql = "SELECT 1;`nGO`nALTER TABLE [dbo].[T] $(' ' * 1500) DROP COLUMN [C];" }
    )
    $commandIndex = 0
    foreach ($command in @(
        ':quit',
        ':exit',
        ':connect tcp:other.example.test',
        ':r .\other.sql',
        ':on error ignore',
        ':out output.txt',
        ':error error.txt',
        '!! whoami',
        ':unknown value',
        '   :QuIt'
    )) {
        $commandIndex++
        $sqlCmdAndAlterPolicyCases += @{
            Name = "sqlcmd-command-$commandIndex"
            Sql = "$command`nSELECT 1;"
        }
    }
    foreach ($case in $sqlCmdAndAlterPolicyCases) {
        $casePath = Join-Path $temporaryPath "$($case.Name).sql"
        $caseReportPath = Join-Path $temporaryPath "$($case.Name).md"
        Set-Content -Path $casePath -Value $case.Sql -Encoding utf8
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
                -ScriptPath $casePath `
                -ReportPath $caseReportPath
        } "SQLCMD/ALTER policy case '$($case.Name)' must fail closed."
    }
    $longAlterColumnPath = Join-Path $temporaryPath 'alter-long-block-comment.sql'
    $longAlterColumnReport = Join-Path $temporaryPath 'alter-long-block-comment.md'
    Set-Content `
        -Path $longAlterColumnPath `
        -Value "ALTER TABLE [dbo].[T] /*$('x' * 10000)*/ ALTER COLUMN [C] int NULL;" `
        -Encoding utf8
    & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
        -ScriptPath $longAlterColumnPath `
        -ReportPath $longAlterColumnReport
    Assert-True `
        -Condition ((Get-Content -Path $longAlterColumnReport -Raw) -match 'DEPLOY006') `
        -Message 'A long ALTER COLUMN statement must retain its compatibility warning.'
    foreach ($case in @(
        @{ Name = 'sqlcmd-command-in-string'; Sql = "PRINT N':quit';" },
        @{ Name = 'sqlcmd-command-in-multiline-string'; Sql = "PRINT N'first`n:quit`nlast';" },
        @{ Name = 'sqlcmd-command-in-comment'; Sql = "/*`n:quit`n*/`nSELECT 1;" },
        @{
            Name = 'sqlcmd-safe-dacfx-values'
            Sql = @'
:setvar DatabaseName "App-Db 01"
:setvar DefaultFilePrefix "App_Db-01"
:setvar DefaultDataPath "C:\Program Files\Microsoft SQL Server\Data\"
:setvar DefaultLogPath "/var/opt/mssql/data/"
SELECT N'$(DatabaseName)', N'$(DefaultFilePrefix)', N'$(DefaultDataPath)', N'$(DefaultLogPath)';
'@
        }
    )) {
        $casePath = Join-Path $temporaryPath "$($case.Name).sql"
        Set-Content -Path $casePath -Value $case.Sql -Encoding utf8
        & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
            -ScriptPath $casePath `
            -ReportPath (Join-Path $temporaryPath "$($case.Name).md")
    }
    $sqlCmdSensitiveValue = "phase8-x' DELETE FROM dbo.T--"
    $sqlCmdSensitivePath = Join-Path $temporaryPath 'sqlcmd-sensitive-value.sql'
    Set-Content `
        -Path $sqlCmdSensitivePath `
        -Value ":setvar Name `"$sqlCmdSensitiveValue`"`nSELECT N'`$(Name)';" `
        -Encoding utf8
    $sqlCmdSensitiveError = ''
    try {
        & (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
            -ScriptPath $sqlCmdSensitivePath `
            -ReportPath (Join-Path $temporaryPath 'sqlcmd-sensitive-value.md')
    }
    catch {
        $sqlCmdSensitiveError = $_.Exception.Message
    }
    Assert-True `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($sqlCmdSensitiveError) -and
            $sqlCmdSensitiveError -notmatch [regex]::Escape($sqlCmdSensitiveValue)
        ) `
        -Message 'Rejected SQLCMD values must fail without echoing raw content.'
    $deploymentGateText = Get-Content `
        -Path (Join-Path $PSScriptRoot 'Test-DeploymentScript.ps1') `
        -Raw
    $sqlCmdCommonText = Get-Content `
        -Path (Join-Path $PSScriptRoot 'SqlCmd.Common.psm1') `
        -Raw
    $instanceDeploymentText = Get-Content `
        -Path (Join-Path $PSScriptRoot 'Deploy-InstanceObjects.ps1') `
        -Raw
    Assert-True `
        -Condition (
            $deploymentGateText -notmatch 'function\s+ConvertTo-SqlToken' -and
            $deploymentGateText -notmatch 'function\s+ConvertTo-CodeOnly' -and
            $deploymentGateText -match 'SqlCmd\.Common\\Test-ConstantDynamicDdl' -and
            $sqlCmdCommonText -match 'function\s+Test-SqlDynamicExecution' -and
            $instanceDeploymentText -match 'Test-SqlInstanceGuardCoverage' -and
            $instanceDeploymentText -match 'Test-SqlDestructiveInstanceStatement' -and
            $instanceDeploymentText -match 'Test-SqlDynamicExecution'
        ) `
        -Message 'Deployment and instance safety must share the common SQL lexer and token helpers.'
    $lexicalRecoveryBypassPath = Join-Path $temporaryPath 'postdeploy-lexical-confusion.sql'
    (
        Get-TestDeploymentScript -DatabaseName CanaryDb -PostDeploymentOnly
    ).Replace(
        '    PRINT N''SQLCMD mode is required.'';',
        "    PRINT N'ok/*'; EXEC xp_cmdshell('evil'); SELECT N'dummy*/dummy2';"
    ) | Set-Content -Path $lexicalRecoveryBypassPath -Encoding utf8
    Assert-Throws {
        Get-DacFxPostDeploymentPayload `
            -Path $lexicalRecoveryBypassPath `
            -RequirePostDeploymentOnly
    } 'Recovery shell validation must not strip comment markers inside SQL string literals.'

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
        -Condition ($templateText -match 'artifactName:\s*deployment-review-\$\{\{\s*parameters\.environmentName\s*\}\}-pitr-marker') `
        -Message 'The deployment review PITR marker artifact is missing.'
    Assert-True `
        -Condition (
            $templateText -match "(?s)condition:\s*and\(always\(\),\s*eq\(variables\['pitrMarkerCreated'\],\s*'true'\)\).*?artifactName:\s*deployment-review-\$\{\{\s*parameters\.environmentName\s*\}\}-pitr-marker"
        ) `
        -Message 'PITR marker publishing must run under cancellation with condition always().'
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
        '(?s)- task: AzureCLI@2\s+displayName: Deploy canary, test, then fan out(?<task>.*?)(?=\r?\n\s+- task: PublishPipelineArtifact@1)'
    ).Groups['task'].Value
    Assert-True `
        -Condition ($rolloutTask -match '(?m)^\s+keepAzSessionActive:\s*true\s*$') `
        -Message 'The long-running WIF rollout task must keep its Azure CLI session active.'
    Assert-True `
        -Condition (
            $templateText -match '(?s)displayName: Run advisory AI review of deployment SQL.*?Remove-Item.*?ai-review\.json.*?ai-review\.md.*?Invoke-AiDatabaseReview'
        ) `
        -Message 'The AI review task must remove known stale outputs before the current review.'
    $deploymentExecutorText = Get-Content `
        -Path (Join-Path $PSScriptRoot 'Invoke-ValidatedDeploymentScript.ps1') `
        -Raw
    Assert-True `
        -Condition (
            $deploymentExecutorText -match 'Invoke-Sqlcmd' -and
            $deploymentExecutorText -match 'Query\s*=\s*\$sqlCmdResolution\.SanitizedText' -and
            $deploymentExecutorText -notmatch '\bInputFile\s*=' -and
            $deploymentExecutorText -notmatch '\$sanitizedPath' -and
            $deploymentExecutorText -match 'AccessToken\s*=\s*\$AccessToken' -and
            $deploymentExecutorText -match 'AbortOnError\s*=\s*\$true' -and
            $deploymentExecutorText -match 'DisableCommands\s*=\s*\$true' -and
            $deploymentExecutorText -match 'DisableVariables\s*=\s*\$true' -and
            $deploymentExecutorText -match 'ExpectedSanitizedSha256' -and
            $deploymentExecutorText -match 'SanitizedSha256\s+-cne' -and
            $deploymentExecutorText -match "Encrypt\s*=\s*'Mandatory'" -and
            $deploymentExecutorText -match 'TrustServerCertificate\s*=\s*\$false'
        ) `
        -Message 'Exact execution must pass validated sanitized SQL in memory and disable secondary SQLCMD parsing.'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Invoke-ValidatedDeploymentScript.ps1') `
            -ServerName 'sqlmi.example.test' `
            -DatabaseName 'AppDb' `
            -AccessToken 'fixture-token' `
            -ScriptPath (Join-Path $fixtures 'deployment-safe.sql') `
            -ExpectedSanitizedSha256 ('0' * 64)
    } 'Exact execution must reject a sanitized SQL hash that differs from the policy gate output.'
    Import-Module (Join-Path $PSScriptRoot 'SqlCmd.Common.psm1') -Force
    $executorFixturePath = Join-Path $fixtures 'deployment-safe.sql'
    $executorResolution = Resolve-SqlCmdScript -Path $executorFixturePath
    $deploymentQueryCallPath = Join-Path $temporaryPath 'deployment-query-call.json'
    $env:PHASE2_SQLCMD_MOCK_PATH = $deploymentQueryCallPath
    function global:Invoke-Sqlcmd {
        [CmdletBinding()]
        param(
            [string]$ServerInstance,
            [string]$Database,
            [string]$AccessToken,
            [string]$Query,
            [switch]$DisableCommands,
            [switch]$DisableVariables,
            [switch]$AbortOnError,
            [string]$Encrypt,
            [switch]$TrustServerCertificate,
            [int]$ConnectionTimeout,
            [int]$QueryTimeout
        )

        [pscustomobject]@{
            ServerInstance = $ServerInstance
            Database = $Database
            AccessTokenLength = $AccessToken.Length
            QuerySha256 = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($Query)
                )
            )
            DisableCommands = $DisableCommands.IsPresent
            DisableVariables = $DisableVariables.IsPresent
            AbortOnError = $AbortOnError.IsPresent
            Encrypt = $Encrypt
            TrustServerCertificate = $TrustServerCertificate.IsPresent
            ConnectionTimeout = $ConnectionTimeout
            QueryTimeout = $QueryTimeout
        } |
            ConvertTo-Json -Compress |
            Set-Content -Path $env:PHASE2_SQLCMD_MOCK_PATH -Encoding utf8
    }
    try {
        & (Join-Path $PSScriptRoot 'Invoke-ValidatedDeploymentScript.ps1') `
            -ServerName 'sqlmi.example.test' `
            -DatabaseName 'AppDb' `
            -AccessToken 'fixture-token' `
            -ScriptPath $executorFixturePath `
            -ExpectedSanitizedSha256 $executorResolution.SanitizedSha256
    }
    finally {
        Remove-Item Function:\global:Invoke-Sqlcmd -Force
        Remove-Item Env:\PHASE2_SQLCMD_MOCK_PATH -ErrorAction SilentlyContinue
    }
    $deploymentQueryCall = Get-Content -Path $deploymentQueryCallPath -Raw | ConvertFrom-Json
    Assert-True `
        -Condition (
            $deploymentQueryCall.QuerySha256 -ceq $executorResolution.SanitizedSha256 -and
            $deploymentQueryCall.DisableCommands -and
            $deploymentQueryCall.DisableVariables -and
            $deploymentQueryCall.AbortOnError
        ) `
        -Message 'Deployment execution Query must be the exact policy-validated sanitized SQL hash.'

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
    $lines = @(
        '/*',
        "Deployment script for $database",
        '*/',
        'GO',
        'SET ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, ARITHABORT, CONCAT_NULL_YIELDS_NULL, QUOTED_IDENTIFIER ON;',
        'SET NUMERIC_ROUNDABORT OFF;',
        'GO',
        ":setvar DatabaseName `"$database`"",
        ":setvar DefaultFilePrefix `"$database`"",
        ':setvar DefaultDataPath "/var/opt/mssql/data/"',
        ':setvar DefaultLogPath "/var/opt/mssql/data/"',
        ':setvar Predicate "1=1"',
        'GO',
        ':on error exit',
        'GO',
        ':setvar __IsSqlCmdEnabled "True"',
        'GO',
        'IF N''$(__IsSqlCmdEnabled)'' NOT LIKE N''True''',
        'BEGIN',
        '    PRINT N''SQLCMD mode is required.'';',
        '    SET NOEXEC ON;',
        'END',
        'GO',
        'USE [$(DatabaseName)];',
        'GO'
    )
    if ($env:PHASE2_POSTDEPLOY_MARKER_MODE -eq 'lexical-confusion') {
        $printIndex = $lines.IndexOf('    PRINT N''SQLCMD mode is required.'';')
        $lines[$printIndex] = "    PRINT N'ok/*'; EXEC xp_cmdshell('evil'); SELECT N'dummy*/dummy2';"
    }
    $postDeploymentOnly = (
        $env:PHASE2_POSTDEPLOY_ONLY_DATABASE -eq '*' -or
        $database -eq $env:PHASE2_POSTDEPLOY_ONLY_DATABASE
    )
    if (-not $postDeploymentOnly) {
        $lines += 'SELECT 42;'
    }
    elseif ($env:PHASE2_POSTDEPLOY_MARKER_MODE -eq 'predeploy') {
        $lines += 'SELECT 99;'
    }
    if ($env:PHASE2_POSTDEPLOY_MARKER_MODE -ne 'missing') {
        $lines += '-- SQLMI-CICD POSTDEPLOY START v1'
    }
    if ($env:PHASE2_POSTDEPLOY_MARKER_MODE -eq 'duplicate') {
        $lines += '-- SQLMI-CICD POSTDEPLOY START v1'
    }
    switch ($env:PHASE2_SQLCMD_MUTATION) {
        'predicate' {
            $predicateIndex = $lines.IndexOf(':setvar Predicate "1=1"')
            $lines[$predicateIndex] = ':setvar Predicate "1=0"'
        }
        'extra' {
            $predicateIndex = $lines.IndexOf(':setvar Predicate "1=1"')
            $lines = @(
                $lines[0..$predicateIndex]
                ':setvar Extra "unexpected"'
                $lines[($predicateIndex + 1)..($lines.Count - 1)]
            )
        }
        'removed' {
            $lines = @($lines | Where-Object { $_ -cne ':setvar Predicate "1=1"' })
        }
    }
    $lines += $(if ($env:PHASE2_POSTDEPLOY_PAYLOAD) {
        $env:PHASE2_POSTDEPLOY_PAYLOAD
    }
    else {
        "IF N'`$(Predicate)' = N'1=1' SELECT 1;"
    })
    $lines += @(
        '-- SQLMI-CICD POSTDEPLOY END v1',
        'GO',
        'GO',
        'PRINT N''Update complete.'';',
        'GO'
    )
    $script = $lines -join "`n"
    if ($database -eq $env:PHASE2_DESTRUCTIVE_DATABASE) {
        $script += "`nDROP TABLE [app].[Danger];"
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
            $successfulManifest.manifestVersion -eq 5 -and
            $successfulManifest.dacpacSha256 -eq (Get-FileHash $fakeDacpac -Algorithm SHA256).Hash -and
            $successfulManifest.postDeploymentContract -eq 'sqlmi-cicd-postdeploy-v1' -and
            $successfulManifest.postDeploymentPayloadSha256 -match '^[A-F0-9]{64}$' -and
            $successfulManifest.postDeploymentSemanticSha256 -match '^[A-F0-9]{64}$' -and
            $successfulManifest.postDeploymentCanonicalVariableMapSha256 -match '^[A-F0-9]{64}$' -and
            @($successfulManifest.postDeploymentRuntimeVariables).Count -eq 4 -and
            @($successfulManifest.artifacts).Count -eq 9 -and
            $successfulManifest.allDatabasePlansValidated -and
            $successfulManifest.allDatabaseScriptsGated -and
            @($successfulManifest.gatedDatabases).Count -eq 2
        ) `
        -Message 'A successful full Plan manifest must bind the DACPAC and every gated artifact with SHA-256.'
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
    $actionLogDirectory = Join-Path $temporaryPath 'deployment-actions'
    New-Item -ItemType Directory -Force -Path $actionLogDirectory | Out-Null
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
Add-Content `
    -Path (Join-Path $env:PHASE2_ACTION_LOG_DIRECTORY "$DatabaseName.log") `
    -Value 'SMOKE' `
    -Encoding utf8
'@ | Set-Content -Path $fakeSmokeTest -Encoding utf8
    $fakeDeploymentScriptExecutor = Join-Path $temporaryPath 'fake-deployment-script-executor.ps1'
    @'
param(
    [string]$ServerName,
    [int]$Port,
    [string]$DatabaseName,
    [string]$AccessToken,
    [string]$ScriptPath,
    [string]$ExpectedSanitizedSha256,
    [int]$CommandTimeout
)
if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    throw 'The deployment script executor did not receive a refreshed access token.'
}
if (-not (Test-Path $ScriptPath -PathType Leaf)) {
    throw 'The deployment script executor did not receive the generated script path.'
}
if ($ExpectedSanitizedSha256 -notmatch '^[A-F0-9]{64}$') {
    throw 'The deployment script executor did not receive the policy-gated sanitized SQL hash.'
}
Add-Content `
    -Path (Join-Path $env:PHASE2_ACTION_LOG_DIRECTORY "$DatabaseName.log") `
    -Value "EXECUTE:$ScriptPath" `
    -Encoding utf8
if ($DatabaseName -eq $env:PHASE2_EXECUTION_FAIL_DATABASE) {
    throw "Fixture deployment script execution failed for '$DatabaseName'."
}
'@ | Set-Content -Path $fakeDeploymentScriptExecutor -Encoding utf8

    $approvedRoot = Join-Path $temporaryPath 'approved-review'
    $approvedReports = Join-Path $approvedRoot 'all-database-reports'
    $approvedScripts = Join-Path $approvedRoot 'all-database-scripts'
    $approvedPolicyReports = Join-Path $approvedRoot 'all-database-policy-reports'
    New-Item -ItemType Directory -Force -Path $approvedReports | Out-Null
    New-Item -ItemType Directory -Force -Path $approvedScripts | Out-Null
    New-Item -ItemType Directory -Force -Path $approvedPolicyReports | Out-Null
    Copy-Item (Join-Path $fixtures 'deploy-report-changed.xml') (Join-Path $approvedRoot 'deploy-report.xml')
    $representativeScript = Get-TestDeploymentScript -DatabaseName CanaryDb
    Set-Content -Path (Join-Path $approvedRoot 'deploy.sql') -Value $representativeScript -Encoding utf8
    Set-Content -Path (Join-Path $approvedRoot 'deployment-script-policy.md') -Value '# passed' -Encoding utf8
    $deploymentTargets = @('CanaryDb', 'Shard02', 'Shard03', 'Shard04')
    foreach ($database in $deploymentTargets) {
        Copy-Item `
            -Path (Join-Path $fixtures 'deploy-report-changed.xml') `
            -Destination (Join-Path $approvedReports "$database.deploy-report.xml")
        $databaseScript = Get-TestDeploymentScript -DatabaseName $database
        Set-Content -Path (Join-Path $approvedScripts "$database.deploy.sql") -Value $databaseScript -Encoding utf8
        Set-Content -Path (Join-Path $approvedPolicyReports "$database.deployment-script-policy.md") -Value '# passed' -Encoding utf8
    }
    $manifestPath = Join-Path $approvedRoot 'target-databases.json'
    $deployArguments = @{
        ServerName = 'sqlmi.example.test'
        DatabaseNames = $deploymentTargets -join ','
        DacpacPath = $fakeDacpac
        PublishProfilePath = $fakeProfile
        SqlPackagePath = $fakeSqlPackage
        ApprovedReportPath = Join-Path $approvedRoot 'deploy-report.xml'
        AccessTokenProviderPath = $fakeTokenProvider
        SmokeTestScriptPath = $fakeSmokeTest
        DeploymentScriptExecutorPath = $fakeDeploymentScriptExecutor
        TestPath = $fixtures
        MaxParallel = 3
        EnvironmentName = 'fixture'
    }

    Write-TestDeploymentManifest $approvedRoot $fakeDacpac $deploymentTargets $true
    Remove-Item $manifestPath -Force
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
            -ValidateAllDatabasePlans `
            -ReportDirectory (Join-Path $temporaryPath 'missing-manifest')
    } 'Deployment must fail closed when the approved manifest is missing.'

    $manifestMutations = @(
        @{ Name = 'non-integral version'; Apply = { param($m) $m.manifestVersion = 4.1 } },
        @{ Name = 'validation mode mismatch'; Apply = { param($m) $m.allDatabasePlansValidated = $false } },
        @{ Name = 'database list mismatch'; Apply = { param($m) $m.targetDatabases[1] = 'WrongShard' } },
        @{ Name = 'DACPAC hash mismatch'; Apply = { param($m) $m.dacpacSha256 = '0' * 64 } },
        @{ Name = 'post-deployment hash mismatch'; Apply = { param($m) $m.postDeploymentPayloadSha256 = '0' * 64 } },
        @{ Name = 'post-deployment semantic hash mismatch'; Apply = { param($m) $m.postDeploymentSemanticSha256 = '0' * 64 } },
        @{ Name = 'post-deployment variable map mismatch'; Apply = { param($m) $m.postDeploymentCanonicalVariableMapSha256 = '0' * 64 } },
        @{ Name = 'post-deployment runtime mapping mismatch'; Apply = { param($m) $m.postDeploymentRuntimeVariables[0].mapping = 'approvedValue' } },
        @{ Name = 'path traversal'; Apply = { param($m) $m.artifacts[0].path = '../deploy-report.xml' } },
        @{
            Name = 'case-insensitive duplicate path'
            Apply = {
                param($m)
                $m.artifacts[1].path = $m.artifacts[0].path.ToUpperInvariant()
            }
        }
    )
    foreach ($mutation in $manifestMutations) {
        Write-TestDeploymentManifest $approvedRoot $fakeDacpac $deploymentTargets $true
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        & $mutation.Apply $manifest
        $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath -Encoding utf8
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
                -ValidateAllDatabasePlans `
                -ReportDirectory (Join-Path $temporaryPath 'invalid-manifest')
        } "Deployment must reject manifest defect: $($mutation.Name)."
    }

    foreach ($artifactRelativePath in @(
        'deploy-report.xml',
        'deploy.sql',
        'deployment-script-policy.md',
        'all-database-reports/Shard02.deploy-report.xml',
        'all-database-scripts/Shard02.deploy.sql',
        'all-database-policy-reports/Shard02.deployment-script-policy.md'
    )) {
        Write-TestDeploymentManifest $approvedRoot $fakeDacpac $deploymentTargets $true
        $artifactPath = Join-Path $approvedRoot $artifactRelativePath
        $originalContent = Get-Content $artifactPath -Raw
        Add-Content -Path $artifactPath -Value 'tampered' -Encoding utf8
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
                -ValidateAllDatabasePlans `
                -ReportDirectory (Join-Path $temporaryPath 'tampered-artifact')
        } "Deployment must reject a tampered approved $artifactRelativePath artifact."
        Set-Content -Path $artifactPath -Value $originalContent -NoNewline -Encoding utf8
    }

    Write-TestDeploymentManifest $approvedRoot $fakeDacpac $deploymentTargets $true
    $originalDacpac = Get-Content $fakeDacpac -Raw
    Add-Content -Path $fakeDacpac -Value 'tampered' -Encoding utf8
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
            -ValidateAllDatabasePlans `
            -ReportDirectory (Join-Path $temporaryPath 'tampered-dacpac')
    } 'Deployment must reject a downloaded DACPAC that differs from the approved hash.'
    Set-Content -Path $fakeDacpac -Value $originalDacpac -NoNewline -Encoding utf8

    Write-TestDeploymentManifest $approvedRoot $fakeDacpac $deploymentTargets $true
    $env:PHASE2_TOKEN_LOG_DIRECTORY = $tokenLogDirectory
    $env:PHASE2_ACTION_LOG_DIRECTORY = $actionLogDirectory
    Remove-Item -Path $planLog -Force -ErrorAction SilentlyContinue
    & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
        -ValidateAllDatabasePlans `
        -ReportDirectory (Join-Path $temporaryPath 'gated-current-reports')
    foreach ($database in $deploymentTargets) {
        $tokenCalls = @(Get-Content -Path (Join-Path $tokenLogDirectory "$database.log"))
        Assert-Equal $tokenCalls.Count 4 "Deployment '$database' must refresh before report, script execution, and smoke test."
    }
    $canarySqlPackageActions = @(
        Get-Content $planLog |
            Where-Object { $_ -match '^(?:ACTION:[^:]+|EXECUTE|SMOKE):CanaryDb' } |
            ForEach-Object { ($_ -split ':')[1] }
    )
    Assert-Equal ($canarySqlPackageActions -join '|') `
        'DeployReport|Script' `
        'Deployment must not recalculate a plan after current Script generation.'
    $canaryExecutionActions = @(Get-Content (Join-Path $actionLogDirectory 'CanaryDb.log'))
    Assert-True `
        -Condition (
            $canaryExecutionActions.Count -eq 2 -and
            $canaryExecutionActions[0] -like 'EXECUTE:*CanaryDb.deploy.sql' -and
            $canaryExecutionActions[1] -eq 'SMOKE'
        ) `
        -Message 'Deployment must execute the generated current script path and then run smoke.'
    Assert-True `
        -Condition ((Get-Content $planLog -Raw) -notmatch 'ACTION:Publish:') `
        -Message 'The Deploy path must not invoke SqlPackage Publish after validating the generated script.'

    Remove-Item -Path (Join-Path $tokenLogDirectory '*.log') -Force
    Remove-Item -Path (Join-Path $actionLogDirectory '*.log') -Force
    Remove-Item -Path $planLog -Force
    $env:PHASE2_DESTRUCTIVE_DATABASE = 'CanaryDb'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
            -ValidateAllDatabasePlans `
            -ReportDirectory (Join-Path $temporaryPath 'aba-current-reports')
    } 'A destructive current script must stop publish even when the current report matches approval.'
    $abaActions = @(Get-Content $planLog)
    Assert-True `
        -Condition (
            ($abaActions -join '|') -match 'ACTION:DeployReport:CanaryDb\|ACTION:Script:CanaryDb' -and
            -not (Test-Path (Join-Path $actionLogDirectory 'CanaryDb.log'))
        ) `
        -Message 'The ABA regression must fail after current script generation and before exact execution.'
    Remove-Item Env:PHASE2_DESTRUCTIVE_DATABASE

    foreach ($database in $deploymentTargets) {
        Copy-Item `
            -Path (Join-Path $fixtures 'deploy-report-empty.xml') `
            -Destination (Join-Path $approvedReports "$database.deploy-report.xml") `
            -Force
    }
    Copy-Item `
        -Path (Join-Path $fixtures 'deploy-report-empty.xml') `
        -Destination (Join-Path $approvedRoot 'deploy-report.xml') `
        -Force
    $env:PHASE2_CHANGED_REPORT = Join-Path $fixtures 'deploy-report-empty.xml'
    Write-TestDeploymentManifest $approvedRoot $fakeDacpac $deploymentTargets $true
    Remove-Item -Path $planLog -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $tokenLogDirectory '*.log') -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $actionLogDirectory '*.log') -Force -ErrorAction SilentlyContinue
    & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
        -ValidateAllDatabasePlans `
        -ReportDirectory (Join-Path $temporaryPath 'empty-report-current')
    foreach ($database in $deploymentTargets) {
        $emptyReportActions = @(Get-Content (Join-Path $actionLogDirectory "$database.log"))
        Assert-True `
            -Condition (
                @($emptyReportActions | Where-Object { $_ -like 'EXECUTE:*' }).Count -eq 1 -and
                @($emptyReportActions | Where-Object { $_ -eq 'SMOKE' }).Count -eq 1
            ) `
            -Message "Empty DeployReport must still execute the exact script and smoke test for '$database'."
    }

    foreach ($database in $deploymentTargets) {
        Copy-Item `
            -Path (Join-Path $fixtures 'deploy-report-changed.xml') `
            -Destination (Join-Path $approvedReports "$database.deploy-report.xml") `
            -Force
    }
    Copy-Item `
        -Path (Join-Path $fixtures 'deploy-report-changed.xml') `
        -Destination (Join-Path $approvedRoot 'deploy-report.xml') `
        -Force
    $env:PHASE2_CHANGED_REPORT = Join-Path $fixtures 'deploy-report-changed.xml'
    Write-TestDeploymentManifest $approvedRoot $fakeDacpac $deploymentTargets $true
    Remove-Item -Path $planLog -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $actionLogDirectory '*.log') -Force -ErrorAction SilentlyContinue
    $env:PHASE2_CHANGED_REPORT = Join-Path $fixtures 'deploy-report-empty.xml'
    $env:PHASE2_POSTDEPLOY_ONLY_DATABASE = '*'
    & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
        -ValidateAllDatabasePlans `
        -ReportDirectory (Join-Path $temporaryPath 'postdeploy-recovery-current')
    foreach ($database in $deploymentTargets) {
        $recoveryActions = @(Get-Content (Join-Path $actionLogDirectory "$database.log"))
        Assert-Equal ($recoveryActions -join '|') `
            "EXECUTE:$([IO.Path]::Combine($temporaryPath, 'postdeploy-recovery-current', "$database.deploy.sql"))|SMOKE" `
            "Post-deployment-only recovery must execute the approved payload and smoke '$database'."
    }

    foreach ($recoveryFailure in @(
        @{ Name = 'payload changed'; Report = 'deploy-report-empty.xml'; Payload = 'SELECT 2;'; Marker = ''; SqlCmd = '' },
        @{ Name = 'schema operation remains'; Report = 'deploy-report-changed.xml'; Payload = ''; Marker = ''; SqlCmd = '' },
        @{ Name = 'marker missing'; Report = 'deploy-report-empty.xml'; Payload = ''; Marker = 'missing'; SqlCmd = '' },
        @{ Name = 'marker duplicated'; Report = 'deploy-report-empty.xml'; Payload = ''; Marker = 'duplicate'; SqlCmd = '' },
        @{ Name = 'predeploy SQL mixed'; Report = 'deploy-report-empty.xml'; Payload = ''; Marker = 'predeploy'; SqlCmd = '' },
        @{ Name = 'string comment confusion'; Report = 'deploy-report-empty.xml'; Payload = ''; Marker = 'lexical-confusion'; SqlCmd = '' },
        @{ Name = 'SQLCMD predicate changed'; Report = 'deploy-report-empty.xml'; Payload = ''; Marker = ''; SqlCmd = 'predicate' },
        @{ Name = 'SQLCMD variable added'; Report = 'deploy-report-empty.xml'; Payload = ''; Marker = ''; SqlCmd = 'extra' },
        @{ Name = 'SQLCMD variable removed'; Report = 'deploy-report-empty.xml'; Payload = ''; Marker = ''; SqlCmd = 'removed' }
    )) {
        Remove-Item -Path $planLog -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $actionLogDirectory '*.log') -Force -ErrorAction SilentlyContinue
        $env:PHASE2_CHANGED_REPORT = Join-Path $fixtures $recoveryFailure.Report
        $env:PHASE2_POSTDEPLOY_PAYLOAD = $recoveryFailure.Payload
        $env:PHASE2_POSTDEPLOY_MARKER_MODE = $recoveryFailure.Marker
        $env:PHASE2_SQLCMD_MUTATION = $recoveryFailure.SqlCmd
        Assert-Throws {
            & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
                -ValidateAllDatabasePlans `
                -ReportDirectory (Join-Path $temporaryPath "postdeploy-reject-$($recoveryFailure.Name.Replace(' ', '-'))")
        } "Post-deployment recovery must reject: $($recoveryFailure.Name)."
        Assert-True `
            -Condition (-not (Test-Path (Join-Path $actionLogDirectory 'CanaryDb.log'))) `
            -Message "Rejected post-deployment recovery '$($recoveryFailure.Name)' must not execute or smoke."
    }
    Remove-Item Env:PHASE2_POSTDEPLOY_PAYLOAD -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_POSTDEPLOY_MARKER_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_SQLCMD_MUTATION -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_POSTDEPLOY_ONLY_DATABASE -ErrorAction SilentlyContinue
    $env:PHASE2_CHANGED_REPORT = Join-Path $fixtures 'deploy-report-changed.xml'
    Write-TestDeploymentManifest $approvedRoot $fakeDacpac $deploymentTargets $true
    Remove-Item -Path $planLog -Force
    Remove-Item -Path (Join-Path $actionLogDirectory '*.log') -Force
    $env:PHASE2_EXECUTION_FAIL_DATABASE = 'CanaryDb'
    Assert-Throws {
        & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
            -ValidateAllDatabasePlans `
            -ReportDirectory (Join-Path $temporaryPath 'execution-failure-current')
    } 'Exact script execution failure must stop smoke and the remaining shard rollout.'
    $executionFailureActions = @(Get-Content (Join-Path $actionLogDirectory 'CanaryDb.log'))
    Assert-True `
        -Condition (
            @($executionFailureActions | Where-Object { $_ -like 'EXECUTE:*' }).Count -eq 1 -and
            @($executionFailureActions | Where-Object { $_ -eq 'SMOKE' }).Count -eq 0 -and
            -not (Test-Path (Join-Path $actionLogDirectory 'Shard02.log')) -and
            -not (Test-Path (Join-Path $actionLogDirectory 'Shard03.log')) -and
            -not (Test-Path (Join-Path $actionLogDirectory 'Shard04.log'))
        ) `
        -Message 'Execution failure must stop before smoke and prevent the parallel shard rollout.'
    Remove-Item Env:PHASE2_EXECUTION_FAIL_DATABASE

    Write-TestDeploymentManifest $approvedRoot $fakeDacpac $deploymentTargets $false
    Remove-Item -Path (Join-Path $tokenLogDirectory '*.log') -Force -ErrorAction SilentlyContinue
    & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
        -ReportDirectory (Join-Path $temporaryPath 'representative-current-reports')
    foreach ($database in $deploymentTargets) {
        $tokenCalls = @(Get-Content -Path (Join-Path $tokenLogDirectory "$database.log"))
        Assert-Equal $tokenCalls.Count 4 "Representative deployment '$database' must refresh before report, script execution, and smoke test."
    }
    $env:PHASE2_CHANGED_REPORT = Join-Path $fixtures 'deploy-report-empty.xml'
    $env:PHASE2_POSTDEPLOY_ONLY_DATABASE = '*'
    Remove-Item -Path (Join-Path $actionLogDirectory '*.log') -Force -ErrorAction SilentlyContinue
    & (Join-Path $PSScriptRoot 'Deploy-Databases.ps1') @deployArguments `
        -ReportDirectory (Join-Path $temporaryPath 'representative-recovery-current')
    foreach ($database in $deploymentTargets) {
        Assert-True `
            -Condition (Test-Path (Join-Path $actionLogDirectory "$database.log")) `
            -Message "Representative recovery must allow the approved runtime target mapping for '$database'."
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
    Remove-Item Env:PHASE2_ACTION_LOG_DIRECTORY -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_EXECUTION_FAIL_DATABASE -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_POSTDEPLOY_ONLY_DATABASE -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_POSTDEPLOY_PAYLOAD -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_POSTDEPLOY_MARKER_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:PHASE2_SQLCMD_MUTATION -ErrorAction SilentlyContinue
    if (Test-Path $temporaryPath) {
        Remove-Item -Path $temporaryPath -Recurse -Force
    }
}
