SET NOCOUNT ON;

IF COL_LENGTH(N'app.FeatureFlag', N'LegacyDescription') IS NULL
BEGIN
    ALTER TABLE [app].[FeatureFlag]
        ADD [LegacyDescription] nvarchar(400) NULL;
END;
GO

UPDATE [app].[FeatureFlag]
SET [LegacyDescription] = CONCAT(N'legacy-', [FlagName]);

ALTER TABLE [app].[FeatureFlag]
    ALTER COLUMN [LegacyDescription] nvarchar(400) NOT NULL;
