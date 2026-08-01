SET NOCOUNT ON;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.key_constraints AS kc
    WHERE kc.[parent_object_id] = OBJECT_ID(N'app.FeatureFlag')
      AND kc.[type] = N'PK'
      AND kc.[name] = N'PK_FeatureFlag'
)
    THROW 51101, 'The FeatureFlag primary-key integrity constraint is missing.', 1;

IF EXISTS
(
    SELECT [FlagName]
    FROM [app].[FeatureFlag]
    GROUP BY [FlagName]
    HAVING COUNT_BIG(*) > 1
)
    THROW 51102, 'FeatureFlag contains duplicate stable identifiers.', 1;

IF EXISTS
(
    SELECT 1
    FROM [app].[FeatureFlag]
    WHERE NULLIF(LTRIM(RTRIM([FlagName])), N'') IS NULL
)
    THROW 51103, 'FeatureFlag contains an empty stable identifier.', 1;

PRINT 'FeatureFlag integrity invariant test passed.';
