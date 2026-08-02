CREATE TABLE [app].[FeatureFlag]
(
    [FlagName] nvarchar(128) NOT NULL,
    [IsEnabled] bit NOT NULL
        CONSTRAINT [DF_FeatureFlag_IsEnabled] DEFAULT (0),
    [Description] nvarchar(512) NULL,
    [Owner] nvarchar(128) NULL,
    [UpdatedAtUtc] datetime2(3) NOT NULL
        CONSTRAINT [DF_FeatureFlag_UpdatedAtUtc] DEFAULT (sysutcdatetime()),
    [Version] rowversion NOT NULL,
    CONSTRAINT [PK_FeatureFlag] PRIMARY KEY CLUSTERED ([FlagName])
);
GO

EXECUTE sys.sp_addextendedproperty
    @name = N'MS_Description',
    @value = N'배포 환경별 기능 활성화 상태를 관리합니다.',
    @level0type = N'SCHEMA',
    @level0name = N'app',
    @level1type = N'TABLE',
    @level1name = N'FeatureFlag';
GO

EXECUTE sys.sp_addextendedproperty
    @name = N'MS_Description',
    @value = N'애플리케이션에서 사용하는 안정적인 기능 식별자입니다.',
    @level0type = N'SCHEMA',
    @level0name = N'app',
    @level1type = N'TABLE',
    @level1name = N'FeatureFlag',
    @level2type = N'COLUMN',
    @level2name = N'FlagName';
