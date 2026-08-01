SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;

EXECUTE [app].[usp_SetFeatureFlag]
    @FlagName = N'integration-test',
    @IsEnabled = 1,
    @Description = N'Created by the integration smoke test.';

IF NOT EXISTS
(
    SELECT 1
    FROM [app].[vEnabledFeatureFlag]
    WHERE [FlagName] = N'integration-test'
)
    THROW 51010, 'Stored procedure did not create an enabled feature flag.', 1;

EXECUTE [app].[usp_SetFeatureFlag]
    @FlagName = N'integration-test',
    @IsEnabled = 0;

IF EXISTS
(
    SELECT 1
    FROM [app].[vEnabledFeatureFlag]
    WHERE [FlagName] = N'integration-test'
)
    THROW 51011, 'Stored procedure did not disable the feature flag.', 1;

ROLLBACK TRANSACTION;

PRINT 'Feature flag behavior smoke test passed.';
