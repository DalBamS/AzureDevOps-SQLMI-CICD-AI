-- Idempotency: create or update the SQL Agent job, step, and local server assignment.
USE [msdb];
GO

DECLARE @JobName sysname = N'$(AgentJobName)';
DECLARE @OwnerLoginName sysname = N'$(AgentJobOwner)';
DECLARE @JobId uniqueidentifier;
DECLARE @StepId int;
DECLARE @StepName sysname = N'Health check';
DECLARE @LocalServerName sysname = N'(LOCAL)';

SELECT @JobId = [job_id]
FROM [msdb].[dbo].[sysjobs]
WHERE [name] = @JobName;

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
        @owner_login_name = @OwnerLoginName,
        @job_id = @JobId OUTPUT;
END
ELSE
BEGIN
    EXEC [msdb].[dbo].[sp_update_job]
        @job_name = @JobName,
        @enabled = 1,
        @description = N'Idempotent CI/CD-managed SQL MI maintenance example.',
        @owner_login_name = @OwnerLoginName;
END;

SELECT @StepId = [step_id]
FROM [msdb].[dbo].[sysjobsteps]
WHERE [job_id] = @JobId
  AND [step_name] = @StepName;

IF EXISTS (
    SELECT 1
    FROM [msdb].[dbo].[sysjobsteps]
    WHERE [job_id] = @JobId
      AND [step_name] = @StepName
)
BEGIN
    EXEC [msdb].[dbo].[sp_update_jobstep]
        @job_id = @JobId,
        @step_id = @StepId,
        @step_name = @StepName,
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'SELECT 1;';
END
ELSE
BEGIN
    EXEC [msdb].[dbo].[sp_add_jobstep]
        @job_id = @JobId,
        @step_name = @StepName,
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command = N'SELECT 1;';
END;

IF NOT EXISTS (
    SELECT 1
    FROM [msdb].[dbo].[sysjobservers]
    WHERE [job_id] = @JobId
      AND [server_id] = 0
)
BEGIN
    EXEC [msdb].[dbo].[sp_add_jobserver]
        @job_id = @JobId,
        @server_name = @LocalServerName;
END;
GO
