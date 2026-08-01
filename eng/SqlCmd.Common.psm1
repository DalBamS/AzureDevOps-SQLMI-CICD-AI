Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-SqlLexicalState {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line,
        [Parameter(Mandatory)]
        [ValidateSet('Code', 'String', 'BracketIdentifier', 'QuotedIdentifier', 'BlockComment')]
        [string]$State,
        [Parameter(Mandatory)]
        [ValidateRange(0, 2147483647)]
        [int]$BlockDepth
    )

    for ($index = 0; $index -lt $Line.Length; $index++) {
        $character = $Line[$index]
        $next = if ($index + 1 -lt $Line.Length) { $Line[$index + 1] } else { [char]0 }
        switch ($State) {
            'Code' {
                if ($character -eq '-' -and $next -eq '-') {
                    return [pscustomobject]@{
                        State = $State
                        BlockDepth = $BlockDepth
                    }
                }
                if ($character -eq '/' -and $next -eq '*') {
                    $State = 'BlockComment'
                    $BlockDepth = 1
                    $index++
                }
                elseif ($character -eq "'") {
                    $State = 'String'
                }
                elseif ($character -eq '[') {
                    $State = 'BracketIdentifier'
                }
                elseif ($character -eq '"') {
                    $State = 'QuotedIdentifier'
                }
            }
            'String' {
                if ($character -eq "'" -and $next -eq "'") {
                    $index++
                }
                elseif ($character -eq "'") {
                    $State = 'Code'
                }
            }
            'BracketIdentifier' {
                if ($character -eq ']' -and $next -eq ']') {
                    $index++
                }
                elseif ($character -eq ']') {
                    $State = 'Code'
                }
            }
            'QuotedIdentifier' {
                if ($character -eq '"' -and $next -eq '"') {
                    $index++
                }
                elseif ($character -eq '"') {
                    $State = 'Code'
                }
            }
            'BlockComment' {
                if ($character -eq '/' -and $next -eq '*') {
                    $BlockDepth++
                    $index++
                }
                elseif ($character -eq '*' -and $next -eq '/') {
                    $BlockDepth--
                    $index++
                    if ($BlockDepth -eq 0) {
                        $State = 'Code'
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        State = $State
        BlockDepth = $BlockDepth
    }
}

function Resolve-SqlCmdVariable {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Variables
    )

    $variableNames = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in $Variables.Keys) {
        [void]$variableNames.Add([string]$name)
    }

    $literalMarker = "__SQLCMD_LITERAL_$([guid]::NewGuid().ToString('N'))__"
    $expanded = $Text.Replace('`$(', $literalMarker)
    $expanded = [regex]::Replace(
        $expanded,
        '\$\((?<name>[A-Za-z_][A-Za-z0-9_]*)\)',
        {
            param($match)

            $name = $match.Groups['name'].Value
            if (-not $variableNames.Contains($name)) {
                throw "Unresolved SQLCMD variable: $name"
            }
            foreach ($key in $Variables.Keys) {
                if ([string]$key -ieq $name) {
                    return [string]$Variables[$key]
                }
            }
            throw "Unresolved SQLCMD variable: $name"
        }
    )
    if ($expanded.Contains('$(')) {
        throw 'Script contains an unresolved or invalid SQLCMD variable reference.'
    }
    return $expanded.Replace($literalMarker, '$(')
}

function Resolve-SqlCmdScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,
        [Collections.IDictionary]$CanonicalVariables = @{}
    )

    $text = (Get-Content -Path $Path -Raw).Replace("`r`n", "`n").Replace("`r", "`n")
    $variables = [ordered]@{}
    $variableNames = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $sanitizedLines = [System.Collections.Generic.List[string]]::new()
    $state = 'Code'
    $blockDepth = 0

    foreach ($line in $text.Split("`n")) {
        $firstNonWhitespace = 0
        while (
            $firstNonWhitespace -lt $line.Length -and
            [char]::IsWhiteSpace($line[$firstNonWhitespace])
        ) {
            $firstNonWhitespace++
        }
        $isCommand = (
            $state -eq 'Code' -and
            $firstNonWhitespace -lt $line.Length -and
            (
                $line[$firstNonWhitespace] -eq ':' -or
                $line.Substring($firstNonWhitespace).StartsWith('!!')
            )
        )
        if ($isCommand) {
            $setVariable = [regex]::Match(
                $line,
                '^(?i)\s*:setvar\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s+"(?<value>[^"\r\n]*)"\s*$'
            )
            if ($setVariable.Success) {
                $name = $setVariable.Groups['name'].Value
                $value = $setVariable.Groups['value'].Value
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
                $sanitizedLines.Add('')
                continue
            }
            if ($line -match '^(?i)\s*:setvar\b') {
                throw "Malformed SQLCMD setvar directive: $line"
            }
            if ($line -match '^(?i)\s*:on\s+error\s+exit\s*$') {
                $sanitizedLines.Add('')
                continue
            }
            throw "SQLCMD control command is not allowed: $($line.Trim())"
        }

        $sanitizedLines.Add($line)
        $lexicalState = Get-SqlLexicalState `
            -Line $line `
            -State $state `
            -BlockDepth $blockDepth
        $state = $lexicalState.State
        $blockDepth = $lexicalState.BlockDepth
    }

    $canonicalValues = [ordered]@{}
    foreach ($name in $CanonicalVariables.Keys) {
        if (-not $variableNames.Contains([string]$name)) {
            throw "Canonical SQLCMD variable is not declared by the script: $name"
        }
    }
    foreach ($name in $variables.Keys) {
        $canonicalValue = $variables[$name]
        foreach ($canonicalName in $CanonicalVariables.Keys) {
            if ([string]$canonicalName -ieq $name) {
                $canonicalValue = [string]$CanonicalVariables[$canonicalName]
                break
            }
        }
        $canonicalValues[$name] = $canonicalValue
    }

    $sanitizedSource = $sanitizedLines -join "`n"
    $sanitizedText = Resolve-SqlCmdVariable -Text $sanitizedSource -Variables $variables
    $canonicalText = Resolve-SqlCmdVariable -Text $sanitizedSource -Variables $canonicalValues
    $canonicalMap = @(
        foreach ($name in @($canonicalValues.Keys | Sort-Object)) {
            "$($name.ToLowerInvariant())=$($canonicalValues[$name])"
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
        ExpandedText = $sanitizedText
        SanitizedText = $sanitizedText
        SanitizedSha256 = Get-TextSha256 -Text $sanitizedText
        CanonicalText = $canonicalText
        Variables = $variableList
        VariableMapSha256 = Get-TextSha256 -Text $canonicalMap
    }
}

Export-ModuleMember -Function 'Resolve-SqlCmdScript'
