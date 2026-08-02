ALTER TABLE [dbo].[LargeOrders]
    ADD [ProcessingRegion] nvarchar(20) NOT NULL
        CONSTRAINT [DF_LargeOrders_ProcessingRegion] DEFAULT (N'unknown') WITH VALUES;

CREATE INDEX [IX_LargeOrders_ProcessingRegion]
    ON [dbo].[LargeOrders] ([ProcessingRegion]);
