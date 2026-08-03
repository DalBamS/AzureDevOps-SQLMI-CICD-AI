SET NOCOUNT ON;

IF SCHEMA_ID(N'app') IS NULL
    THROW 51001, 'Expected schema app was not deployed.', 1;

IF OBJECT_ID(N'app.FeatureFlag', N'U') IS NULL
    THROW 51002, 'Expected table app.FeatureFlag was not deployed.', 1;

IF OBJECT_ID(N'app.vEnabledFeatureFlag', N'V') IS NULL
    THROW 51003, 'Expected view app.vEnabledFeatureFlag was not deployed.', 1;

IF OBJECT_ID(N'app.usp_SetFeatureFlag', N'P') IS NULL
    THROW 51004, 'Expected procedure app.usp_SetFeatureFlag was not deployed.', 1;

IF OBJECT_ID(N'app.usp_SeedFeatureFlags', N'P') IS NULL
    THROW 51007, 'Expected procedure app.usp_SeedFeatureFlags was not deployed.', 1;

IF COL_LENGTH(N'app.FeatureFlag', N'UpdatedBy') IS NULL
    THROW 51008, 'Expected column app.FeatureFlag.UpdatedBy was not deployed.', 1;

IF COL_LENGTH(N'app.FeatureFlag', N'Owner') IS NULL
    THROW 51008, 'Expected column Owner was not deployed.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.extended_properties
    WHERE [major_id] = OBJECT_ID(N'app.FeatureFlag')
      AND [minor_id] = 0
      AND [name] = N'MS_Description'
)
    THROW 51005, 'Expected table metadata was not deployed.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM [app].[FeatureFlag]
    WHERE [FlagName] = N'database-cicd-ready'
      AND [IsEnabled] = 1
)
    THROW 51006, 'Expected reference data was not seeded.', 1;

PRINT 'Schema and metadata smoke test passed.';
