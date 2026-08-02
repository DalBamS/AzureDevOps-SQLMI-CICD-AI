DROP INDEX [IX_FeatureFlag_Name] ON [app].[FeatureFlag];
GO
CREATE INDEX [IX_FeatureFlag_Name] ON [app].[FeatureFlag] ([Name]);
GO
