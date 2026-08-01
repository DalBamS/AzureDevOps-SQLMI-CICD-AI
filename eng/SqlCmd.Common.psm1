Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Resolve-SqlCmdScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path
    )

    $text = Get-Content -Path $Path -Raw
    $variables = [ordered]@{}
    $variableNames = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($line in [regex]::Split($text, '\r?\n')) {
        if ($line -notmatch '^\s*:setvar\b') {
            continue
        }
        $directive = [regex]::Match(
            $line,
            '^(?i)\s*:setvar\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s+"(?<value>[^"\r\n]*)"\s*$'
        )
        if (-not $directive.Success) {
            throw "Malformed SQLCMD setvar directive: $line"
        }
        $name = $directive.Groups['name'].Value
        $value = $directive.Groups['value'].Value
        if (-not $variableNames.Add($name)) {
            throw "Duplicate SQLCMD variable declaration: $name"
        }
        if (
            $value -match '[;\x00-\x1F]' -or
            $value.Contains('$(') -or
            $value.Contains('`')
        ) {
            throw "SQLCMD variable '$name' contains a value that cannot be reviewed safely."
        }
        $variables[$name] = $value
    }

    $literalMarker = "__SQLCMD_LITERAL_$([guid]::NewGuid().ToString('N'))__"
    $expanded = $text.Replace('`$(', $literalMarker)
    $expanded = [regex]::Replace(
        $expanded,
        '\$\((?<name>[A-Za-z_][A-Za-z0-9_]*)\)',
        {
            param($match)

            $name = $match.Groups['name'].Value
            if (-not $variableNames.Contains($name)) {
                throw "Unresolved SQLCMD variable: $name"
            }
            foreach ($key in $variables.Keys) {
                if ($key -ieq $name) {
                    return [string]$variables[$key]
                }
            }
            throw "Unresolved SQLCMD variable: $name"
        }
    )
    if ($expanded.Contains('$(')) {
        throw 'Script contains an unresolved or invalid SQLCMD variable reference.'
    }
    $expanded = $expanded.Replace($literalMarker, '$(')

    $canonicalMap = @(
        foreach ($name in @($variables.Keys | Sort-Object)) {
            "$($name.ToLowerInvariant())=$($variables[$name])"
        }
    ) -join "`n"
    $variableList = @(
        foreach ($name in $variables.Keys) {
            [pscustomobject]@{
                Name = $name
                Value = [string]$variables[$name]
            }
        }
    )
    return [pscustomobject]@{
        ExpandedText = $expanded
        Variables = $variableList
        VariableMapSha256 = Get-TextSha256 -Text $canonicalMap
    }
}

Export-ModuleMember -Function 'Resolve-SqlCmdScript'
