SET NOCOUNT ON;

IF COL_LENGTH(N'app.FeatureFlag', N'DescriptionV2') IS NULL
BEGIN
    ALTER TABLE [app].[FeatureFlag]
        ADD [DescriptionV2] nvarchar(400) NULL;
END;
