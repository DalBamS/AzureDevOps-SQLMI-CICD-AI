CREATE PROCEDURE [app].[usp_SeedFeatureFlags]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [app].[FeatureFlag] WITH (UPDLOCK, HOLDLOCK)
        WHERE [FlagName] = N'database-cicd-ready'
    )
    BEGIN
        INSERT [app].[FeatureFlag] ([FlagName], [IsEnabled], [Description])
        VALUES
        (
            N'database-cicd-ready',
            1,
            N'CI/CD 파이프라인을 통해 관리되는 기준 정적 데이터입니다.'
        );
    END;

    COMMIT TRANSACTION;
END;
