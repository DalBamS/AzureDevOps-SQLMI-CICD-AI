Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ManagedBatchParserTypes = $null

function Get-TextSha256 {
    param([AllowEmptyString()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Test-SqlCmdValue {
    param([AllowEmptyString()][string]$Value, [switch]$AllowEmpty)
    if ([string]::IsNullOrEmpty($Value)) { return $AllowEmpty.IsPresent }
    return (
        $Value -match '^[A-Za-z0-9_.@#:/\\ =\-]+$' -and
        $Value -notmatch '--|/\*|\*/'
    )
}

function Get-SqlCmdReferenceName {
    param([AllowEmptyString()][string]$Text)
    $source = $Text.Replace('`$(', '__ESCAPED_SQLCMD_REFERENCE__')
    return @(
        [regex]::Matches($source, '\$\((?<name>[A-Za-z_][A-Za-z0-9_]*)\)') |
            ForEach-Object { $_.Groups['name'].Value } |
            Sort-Object -Unique
    )
}

function Resolve-SqlCmdScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,
        [Collections.IDictionary]$ExternalVariables = @{},
        [switch]$DisallowSetVariableDirectives,
        [switch]$RequireExactExternalVariables
    )

    $variables = [ordered]@{}
    foreach ($key in $ExternalVariables.Keys) {
        $name = [string]$key
        $value = [string]$ExternalVariables[$key]
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or -not (Test-SqlCmdValue $value)) {
            throw "External SQLCMD variable '$name' is invalid."
        }
        $variables[$name] = $value
    }

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in (Get-Content $Path -Raw).Replace("`r`n", "`n").Replace("`r", "`n").Split("`n")) {
        $setvar = [regex]::Match(
            $line,
            '^(?i)\s*:setvar\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s+"(?<value>[^"\r\n]*)"\s*$'
        )
        if ($setvar.Success) {
            if ($DisallowSetVariableDirectives) {
                throw 'SQLCMD setvar directives are not allowed in this script.'
            }
            $name = $setvar.Groups['name'].Value
            $value = $setvar.Groups['value'].Value
            if ($variables.Keys -contains $name -or -not (Test-SqlCmdValue $value -AllowEmpty)) {
                throw "SQLCMD variable '$name' is duplicate or invalid."
            }
            $variables[$name] = $value
            $lines.Add('')
            continue
        }
        if ($line -match '^(?i)\s*:on\s+error\s+exit\s*$') {
            $lines.Add('')
            continue
        }
        if ($line -match '^\s*(?::|!!)') {
            throw 'SQLCMD control command is not allowed.'
        }
        $lines.Add($line)
    }

    $source = $lines -join "`n"
    $references = @(Get-SqlCmdReferenceName $source)
    if ($RequireExactExternalVariables) {
        $unused = @($ExternalVariables.Keys | Where-Object { $_ -notin $references })
        if ($unused.Count -gt 0) {
            throw "External SQLCMD variable '$($unused[0])' is not referenced."
        }
    }
    $literalMarker = "__SQLCMD_LITERAL_$([guid]::NewGuid().ToString('N'))__"
    $expanded = $source.Replace('`$(', $literalMarker)
    $expanded = [regex]::Replace(
        $expanded,
        '\$\((?<name>[A-Za-z_][A-Za-z0-9_]*)\)',
        {
            param($match)
            $name = $match.Groups['name'].Value
            foreach ($key in $variables.Keys) {
                if ([string]$key -ieq $name) { return [string]$variables[$key] }
            }
            throw "Unresolved SQLCMD variable: $name"
        }
    ).Replace($literalMarker, '$(')
    if ($expanded -match '(?m)^\s*(?::|!!)' -or $expanded.Contains('$(')) {
        throw 'SQLCMD expansion produced an unresolved variable or control command.'
    }
    return [pscustomobject]@{
        ExpandedText = $expanded
        SanitizedText = $expanded
        SanitizedSha256 = Get-TextSha256 $expanded
        Variables = @($variables.GetEnumerator())
    }
}

function Get-SqlManagedBatchParserTypes {
    if ($script:ManagedBatchParserTypes) { return $script:ManagedBatchParserTypes }
    $requiredVersion = if ($env:SQLSERVER_MODULE_VERSION) {
        [version]$env:SQLSERVER_MODULE_VERSION
    } else {
        $null
    }
    $module = @(
        Get-Module -ListAvailable -Name SqlServer |
            Where-Object { -not $requiredVersion -or $_.Version -eq $requiredVersion } |
            Sort-Object Version -Descending
    ) | Select-Object -First 1
    if (-not $module) {
        throw 'Install the SqlServer module version selected by SQLSERVER_MODULE_VERSION.'
    }
    Import-Module $module.Path -Scope Local -Force
    $assembly = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'Microsoft.SqlTools.ManagedBatchParser' } |
        Select-Object -First 1
    if (-not $assembly) {
        throw 'SqlServer module did not load Microsoft.SqlTools.ManagedBatchParser.'
    }
    $script:ManagedBatchParserTypes = [pscustomobject]@{
        Wrapper = $assembly.GetType('Microsoft.SqlTools.ServiceLayer.BatchParser.BatchParserWrapper', $true)
        Conditions = $assembly.GetType(
            'Microsoft.SqlTools.ServiceLayer.BatchParser.ExecutionEngineCode.ExecutionEngineConditions',
            $true
        )
    }
    return $script:ManagedBatchParserTypes
}

function Get-SqlBatch {
    param([AllowEmptyString()][string]$Text)
    $types = Get-SqlManagedBatchParserTypes
    $parser = [Activator]::CreateInstance($types.Wrapper)
    try {
        $conditions = [Activator]::CreateInstance($types.Conditions)
        $conditions.IsSqlCmd = $false
        $conditions.BatchSeparator = 'GO'
        $parsed = @($parser.GetBatches($Text, $conditions))
    }
    finally {
        $parser.Dispose()
    }
    return @(
        $offset = 0
        for ($index = 0; $index -lt $parsed.Count; $index++) {
            $batchText = [string]$parsed[$index].BatchText
            $start = $Text.IndexOf($batchText, $offset, [StringComparison]::Ordinal)
            if ($start -lt 0) { throw 'Managed batch parser returned an unmappable batch.' }
            $offset = $start + $batchText.Length
            [pscustomobject]@{
                BatchIndex = $index
                Text = $batchText
                StartIndex = $start
                EndIndex = $offset
                StartLine = [int]$parsed[$index].StartLine
                BatchExecutionCount = [int]$parsed[$index].BatchExecutionCount
            }
        }
    )
}

function Test-SqlInstanceGuardCoverage {
    param([AllowEmptyString()][string]$Text)
    $hasGuard = $Text -match '(?is)\bIF\s+(?:NOT\s+)?EXISTS\s*\('
    $hasMutation = $Text -match '(?is)\b(?:CREATE|ALTER|INSERT|UPDATE|DELETE|EXEC(?:UTE)?)\b'
    return $hasGuard -and $hasMutation -and $Text -match '(?is)\bBEGIN\b.*\bEND\b'
}

function Test-SqlDestructiveInstanceStatement {
    param([AllowEmptyString()][string]$Text)
    return $Text -match '(?is)\b(?:DROP|TRUNCATE|GRANT|DENY|REVOKE)\b'
}

function Test-SqlDynamicExecution {
    param([AllowEmptyString()][string]$Text)
    return $Text -notmatch '(?is)\bEXEC(?:UTE)?\s*(?:\(|@)|\bsp_executesql\s+@'
}

Export-ModuleMember -Function @(
    'Get-SqlBatch',
    'Get-SqlCmdReferenceName',
    'Resolve-SqlCmdScript',
    'Test-SqlCmdValue',
    'Test-SqlDestructiveInstanceStatement',
    'Test-SqlDynamicExecution',
    'Test-SqlInstanceGuardCoverage'
)
