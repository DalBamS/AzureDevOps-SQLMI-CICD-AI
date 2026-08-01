-- Idempotency: create the Microsoft Entra login only when it does not already exist.
USE [master];
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.server_principals
    WHERE [name] = N'$(EntraLoginName)'
)
BEGIN
    CREATE LOGIN [$(EntraLoginName)] FROM EXTERNAL PROVIDER;
END;
GO
