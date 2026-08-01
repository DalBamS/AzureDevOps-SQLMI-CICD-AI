SET NOCOUNT ON;

UPDATE [app].[FeatureFlag]
SET [DescriptionV2] = [LegacyDescription]
WHERE [DescriptionV2] IS NULL;

IF EXISTS (
    SELECT 1
    FROM [app].[FeatureFlag]
    WHERE [DescriptionV2] IS NULL
)
BEGIN
    THROW 51000, 'DescriptionV2 backfill is incomplete.', 1;
END;

ALTER TABLE [app].[FeatureFlag]
    ALTER COLUMN [DescriptionV2] nvarchar(400) NOT NULL;
