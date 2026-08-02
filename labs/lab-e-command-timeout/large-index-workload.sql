SET NOCOUNT ON;

DROP TABLE IF EXISTS [dbo].[Phase4TimeoutLab];

CREATE TABLE [dbo].[Phase4TimeoutLab]
(
    [Id] bigint IDENTITY(1, 1) NOT NULL,
    [GroupKey] int NOT NULL,
    [Payload] char(200) NOT NULL,
    CONSTRAINT [PK_Phase4TimeoutLab] PRIMARY KEY CLUSTERED ([Id])
);

WITH
    [Digits] AS
    (
        SELECT [value]
        FROM (VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9)) AS [d]([value])
    ),
    [Rows] AS
    (
        SELECT TOP (1000000)
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS [row_number]
        FROM [Digits] AS [a]
        CROSS JOIN [Digits] AS [b]
        CROSS JOIN [Digits] AS [c]
        CROSS JOIN [Digits] AS [d]
        CROSS JOIN [Digits] AS [e]
        CROSS JOIN [Digits] AS [f]
    )
INSERT [dbo].[Phase4TimeoutLab] ([GroupKey], [Payload])
SELECT
    [row_number] % 1000,
    REPLICATE('x', 200)
FROM [Rows];

CREATE INDEX [IX_Phase4TimeoutLab_GroupKey]
    ON [dbo].[Phase4TimeoutLab] ([GroupKey])
    INCLUDE ([Payload]);
