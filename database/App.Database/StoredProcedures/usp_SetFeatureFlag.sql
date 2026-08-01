CREATE PROCEDURE [app].[usp_SetFeatureFlag]
    @FlagName nvarchar(128),
    @IsEnabled bit,
    @Description nvarchar(512) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@FlagName)), N'') IS NULL
        THROW 50001, 'FlagName is required.', 1;

    BEGIN TRANSACTION;

    UPDATE [app].[FeatureFlag] WITH (UPDLOCK, SERIALIZABLE)
    SET
        [IsEnabled] = @IsEnabled,
        [Description] = COALESCE(@Description, [Description]),
        [UpdatedAtUtc] = CONVERT(datetime2(3), sysutcdatetime())
    WHERE [FlagName] = @FlagName;

    IF @@ROWCOUNT = 0
    BEGIN
        INSERT [app].[FeatureFlag] ([FlagName], [IsEnabled], [Description])
        VALUES (@FlagName, @IsEnabled, @Description);
    END;

    COMMIT TRANSACTION;
END;
