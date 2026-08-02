SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    EXECUTE [app].[usp_SetFeatureFlag]
        @FlagName = N'   ',
        @IsEnabled = 1;
    THROW 51121, 'usp_SetFeatureFlag accepted a whitespace-only identifier.', 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 51121
        THROW;
    IF ERROR_NUMBER() <> 50001
        THROW 51122, 'usp_SetFeatureFlag returned the wrong empty-name error.', 1;
END CATCH;

BEGIN TRANSACTION;

DECLARE @MaximumFlagName nvarchar(128) = REPLICATE(N'x', 128);
EXECUTE [app].[usp_SetFeatureFlag]
    @FlagName = @MaximumFlagName,
    @IsEnabled = 1,
    @Description = N'Maximum supported identifier length.';

IF NOT EXISTS
(
    SELECT 1
    FROM [app].[FeatureFlag]
    WHERE [FlagName] = @MaximumFlagName
      AND [IsEnabled] = 1
)
    THROW 51123, 'usp_SetFeatureFlag rejected the maximum supported identifier length.', 1;

ROLLBACK TRANSACTION;

PRINT 'Stored-procedure boundary test passed.';
