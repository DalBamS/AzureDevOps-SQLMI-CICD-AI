SET NOCOUNT ON;

IF EXISTS (
    SELECT 1
    FROM [app].[FeatureFlag]
    WHERE [DescriptionV2] IS NULL
       OR [DescriptionV2] <> [LegacyDescription]
)
BEGIN
    THROW 51001, 'DescriptionV2 verification failed; contract is not safe.', 1;
END;

ALTER TABLE [app].[FeatureFlag]
    DROP COLUMN [LegacyDescription];
