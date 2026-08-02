-- Idempotency: create or update the SQL Agent job, step, and local server assignment.
USE [msdb];
GO

DECLARE @JobName sysname = N'$(AgentJobName)';
DECLARE @OwnerLoginName sysname = N'$(AgentJobOwner)';
DECLARE @StepName sysname = N'Health check';
DECLARE @LocalServerName sysname = N'(LOCAL)';

IF NOT EXISTS (
    SELECT 1
    FROM [msdb].[dbo].[sysjobs]
    WHERE [name] = @JobName
)
BEGIN
    EXEC [msdb].[dbo].[sp_add_job]
        @job_name = @JobName,
        @enabled = 1,
        @description = N'Idempotent CI/CD-managed SQL MI maintenance example.',
        @owner_login_name = @OwnerLoginName;
END
ELSE
BEGIN
    EXEC [msdb].[dbo].[sp_update_job]
        @job_name = @JobName,
        @enabled = 1,
        @description = N'Idempotent CI/CD-managed SQL MI maintenance example.',
        @owner_login_name = @OwnerLoginName;
END;

IF EXISTS (
    SELECT 1
    FROM [msdb].[dbo].[sysjobsteps] AS [jobstep]
    INNER JOIN [msdb].[dbo].[sysjobs] AS [job]
        ON [job].[job_id] = [jobstep].[job_id]
    WHERE [job].[name] = @JobName
      AND [jobstep].[step_id] = 1
      AND [jobstep].[step_name] = @StepName
)
BEGIN
    EXEC [msdb].[dbo].[sp_update_jobstep]
        @job_name = @JobName,
        @step_id = 1,
        @step_name = @StepName,
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'SELECT 1;';
END
ELSE
BEGIN
    EXEC [msdb].[dbo].[sp_add_jobstep]
        @job_name = @JobName,
        @step_id = 1,
        @step_name = @StepName,
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'SELECT 1;';
END;

IF NOT EXISTS (
    SELECT 1
    FROM [msdb].[dbo].[sysjobservers] AS [jobserver]
    INNER JOIN [msdb].[dbo].[sysjobs] AS [job]
        ON [job].[job_id] = [jobserver].[job_id]
    WHERE [job].[name] = @JobName
      AND [jobserver].[server_id] = 0
)
BEGIN
    EXEC [msdb].[dbo].[sp_add_jobserver]
        @job_name = @JobName,
        @server_name = @LocalServerName;
END;
GO
