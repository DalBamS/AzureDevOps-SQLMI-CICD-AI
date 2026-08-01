CREATE VIEW [app].[vEnabledFeatureFlag]
AS
SELECT
    [FlagName],
    [Description],
    [UpdatedAtUtc]
FROM [app].[FeatureFlag]
WHERE [IsEnabled] = 1;
