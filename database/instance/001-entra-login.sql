-- Idempotency: create the Microsoft Entra login only when it does not already exist.
USE [master];
GO

DECLARE @LoginName sysname = N'$(EntraLoginName)';

IF NOT EXISTS (
    SELECT 1
    FROM sys.server_principals
    WHERE [name] = @LoginName
)
BEGIN
    EXEC (N'CREATE LOGIN ' + QUOTENAME(@LoginName) + N' FROM EXTERNAL PROVIDER;');
END;
GO
