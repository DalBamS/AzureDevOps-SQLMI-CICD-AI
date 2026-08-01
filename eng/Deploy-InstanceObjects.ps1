[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$ServerName,
    [ValidateRange(1, 65535)]
    [int]$Port = 1433,
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$DatabaseName = 'master',
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AccessToken,
    [string]$ScriptPath,
    [Parameter(Mandatory)]
    [hashtable]$SqlcmdVariables
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SqlCmd.Common.psm1') -Force

if (-not $ScriptPath) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $ScriptPath = [IO.Path]::Combine($repoRoot, 'database', 'instance')
}
if (-not (Test-Path $ScriptPath -PathType Container)) {
    throw "Instance object script directory not found: $ScriptPath"
}

$scripts = @(
    Get-ChildItem -Path $ScriptPath -File -Filter '*.sql' |
        Sort-Object Name
)
if ($scripts.Count -eq 0) {
    throw "No instance object SQL scripts found in: $ScriptPath"
}

$normalizedVariables = @{}
foreach ($entry in $SqlcmdVariables.GetEnumerator()) {
    $name = [string]$entry.Key
    $value = [string]$entry.Value
    if ($name -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
        throw "Invalid SQLCMD variable name '$name'."
    }
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '^\$\([^)]+\)$') {
        throw "SQLCMD variable '$name' is empty or unresolved."
    }
    if (-not (Test-SqlCmdValue -Value $value)) {
        throw "SQLCMD variable '$name' contains unsupported characters."
    }
    $normalizedVariables[$name] = $value
}

$requiredVariableNames = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
$scriptResolutions = @{}
foreach ($script in $scripts) {
    if ($script.Name -notmatch '^\d{3}-[A-Za-z0-9-]+\.sql$') {
        throw "Instance script '$($script.Name)' must use the NNN-description.sql naming convention."
    }

    $content = Get-Content -Path $script.FullName -Raw
    if ($content -notmatch '(?im)^\s*--\s*Idempotency:\s*\S+') {
        throw "Instance script '$($script.Name)' must document its Idempotency precondition."
    }
    $requiredVariables = @(Get-SqlCmdReferenceName -Text $content)
    foreach ($requiredVariable in $requiredVariables) {
        [void]$requiredVariableNames.Add($requiredVariable)
        if (-not $normalizedVariables.ContainsKey($requiredVariable)) {
            throw "Instance script '$($script.Name)' requires SQLCMD variable '$requiredVariable'."
        }
    }
    $scriptVariables = [ordered]@{}
    foreach ($requiredVariable in $requiredVariables) {
        $scriptVariables[$requiredVariable] = $normalizedVariables[$requiredVariable]
    }
    $resolution = Resolve-SqlCmdScript `
        -Path $script.FullName `
        -ExternalVariables $scriptVariables `
        -DisallowSetVariableDirectives `
        -RequireExactExternalVariables
    if (-not (Test-SqlInstanceGuardCoverage -Text $resolution.SanitizedText)) {
        throw "Instance script '$($script.Name)' must keep every mutation inside an existence guard."
    }
    if (Test-SqlDestructiveInstanceStatement -Text $resolution.SanitizedText) {
        throw "Instance script '$($script.Name)' contains a prohibited destructive operation."
    }
    if (-not (Test-SqlDynamicExecution -Text $resolution.SanitizedText)) {
        throw "Instance script '$($script.Name)' contains dynamic execution that cannot be reviewed safely."
    }
    $scriptResolutions[$script.FullName] = $resolution
}
foreach ($variableName in $normalizedVariables.Keys) {
    if (-not $requiredVariableNames.Contains([string]$variableName)) {
        throw "SQLCMD variable '$variableName' is not referenced by any instance script."
    }
}

$invokeSqlcmd = $null
$serverInstance = "tcp:$ServerName,$Port"

$scriptIndex = 0
foreach ($script in $scripts) {
    $scriptIndex++
    $resolution = $scriptResolutions[$script.FullName]
    Write-Information (
        "Validated instance script $scriptIndex/$($scripts.Count) '$($script.Name)' " +
        "for '$serverInstance/$DatabaseName'; sanitized SHA-256: " +
        $resolution.SanitizedSha256
    ) -InformationAction Continue
    if (-not $PSCmdlet.ShouldProcess(
        "$serverInstance/$DatabaseName",
        "Execute instance script $($script.Name)"
    )) {
        continue
    }

    if (-not $invokeSqlcmd) {
        $invokeSqlcmd = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
        if (-not $invokeSqlcmd) {
            throw 'The pinned SqlServer PowerShell module is required to deploy instance objects.'
        }
    }

    Write-Host "Executing instance object script: $($script.Name)"
    Invoke-Sqlcmd `
        -ServerInstance $serverInstance `
        -Database $DatabaseName `
        -AccessToken $AccessToken `
        -Query $resolution.SanitizedText `
        -DisableCommands `
        -DisableVariables `
        -AbortOnError `
        -Encrypt Mandatory `
        -TrustServerCertificate:$false `
        -ErrorAction Stop
}

Write-Host "Processed $($scripts.Count) instance object script(s) in filename order."
