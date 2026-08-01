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
    if ($value -notmatch '^[A-Za-z0-9_.@# -]+$') {
        throw "SQLCMD variable '$name' contains unsupported characters."
    }
    $normalizedVariables[$name] = $value
}

foreach ($script in $scripts) {
    if ($script.Name -notmatch '^\d{3}-[A-Za-z0-9-]+\.sql$') {
        throw "Instance script '$($script.Name)' must use the NNN-description.sql naming convention."
    }

    $content = Get-Content -Path $script.FullName -Raw
    if ($content -notmatch '(?im)^\s*--\s*Idempotency:\s*\S+') {
        throw "Instance script '$($script.Name)' must document its Idempotency precondition."
    }
    if ($content -notmatch '(?is)\bIF\b.*\bEXISTS\b') {
        throw "Instance script '$($script.Name)' must guard create/update behavior with an existence check."
    }
    if ($content -match '(?is)\bDROP\s+(?:LOGIN|CREDENTIAL)\b|\bsp_delete_job\b') {
        throw "Instance script '$($script.Name)' contains a prohibited destructive operation."
    }

    $requiredVariables = @(
        [regex]::Matches($content, '\$\((?<name>[A-Za-z][A-Za-z0-9_]*)\)') |
            ForEach-Object { $_.Groups['name'].Value } |
            Sort-Object -Unique
    )
    foreach ($requiredVariable in $requiredVariables) {
        if (-not $normalizedVariables.ContainsKey($requiredVariable)) {
            throw "Instance script '$($script.Name)' requires SQLCMD variable '$requiredVariable'."
        }
    }
}

$invokeSqlcmd = $null
$serverInstance = "tcp:$ServerName,$Port"
$sqlcmdVariableArguments = @(
    $normalizedVariables.GetEnumerator() |
        Sort-Object Key |
        ForEach-Object { "$($_.Key)=$($_.Value)" }
)

foreach ($script in $scripts) {
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
        -InputFile $script.FullName `
        -Variable $sqlcmdVariableArguments `
        -AbortOnError `
        -Encrypt Mandatory `
        -TrustServerCertificate:$false `
        -ErrorAction Stop
}

Write-Host "Processed $($scripts.Count) instance object script(s) in filename order."
