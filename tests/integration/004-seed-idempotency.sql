SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;

EXECUTE [app].[usp_SeedFeatureFlags];

DECLARE @CountAfterFirstRun bigint =
(
    SELECT COUNT_BIG(*)
    FROM [app].[FeatureFlag]
);

EXECUTE [app].[usp_SeedFeatureFlags];

DECLARE @CountAfterSecondRun bigint =
(
    SELECT COUNT_BIG(*)
    FROM [app].[FeatureFlag]
);

IF @CountAfterFirstRun <> @CountAfterSecondRun
    THROW 51111, 'Running the reference-data seed twice changed the row count.', 1;

IF
(
    SELECT COUNT_BIG(*)
    FROM [app].[FeatureFlag]
    WHERE [FlagName] = N'database-cicd-ready'
) <> 1
    THROW 51112, 'The reference-data seed must produce exactly one stable row.', 1;

ROLLBACK TRANSACTION;

PRINT 'Reference-data seed idempotency test passed.';
