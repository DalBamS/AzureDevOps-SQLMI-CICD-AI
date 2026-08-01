SET NOCOUNT ON;

DECLARE @PrimaryKeyIndexId int =
(
    SELECT kc.[unique_index_id]
    FROM sys.key_constraints AS kc
    WHERE kc.[parent_object_id] = OBJECT_ID(N'app.FeatureFlag')
      AND kc.[type] = N'PK'
      AND kc.[name] = N'PK_FeatureFlag'
);

IF @PrimaryKeyIndexId IS NULL
    THROW 51131, 'The FeatureFlag primary-key index is missing.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes AS i
    WHERE i.[object_id] = OBJECT_ID(N'app.FeatureFlag')
      AND i.[index_id] = @PrimaryKeyIndexId
      AND i.[type_desc] = N'CLUSTERED'
      AND i.[is_unique] = 1
      AND i.[is_disabled] = 0
)
    THROW 51132, 'The FeatureFlag primary-key index is not enabled, unique, and clustered.', 1;

IF
(
    SELECT COUNT_BIG(*)
    FROM sys.index_columns AS ic
    INNER JOIN sys.columns AS c
        ON c.[object_id] = ic.[object_id]
       AND c.[column_id] = ic.[column_id]
    WHERE ic.[object_id] = OBJECT_ID(N'app.FeatureFlag')
      AND ic.[index_id] = @PrimaryKeyIndexId
      AND ic.[key_ordinal] > 0
      AND c.[name] = N'FlagName'
) <> 1
    THROW 51133, 'The FeatureFlag primary-key index does not key FlagName exactly once.', 1;

PRINT 'FeatureFlag index metadata test passed.';
