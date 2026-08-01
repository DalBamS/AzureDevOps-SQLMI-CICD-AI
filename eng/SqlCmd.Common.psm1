Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SqlServerModuleVersion = [version]'22.4.5.1'
$script:ManagedBatchParserTypes = $null

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

function ConvertTo-SqlLexicalView {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [switch]$MaskString
    )

    $result = [Text.StringBuilder]::new($Text.Length)
    for ($index = 0; $index -lt $Text.Length; $index++) {
        if (
            $Text[$index] -eq '-' -and
            $index + 1 -lt $Text.Length -and
            $Text[$index + 1] -eq '-'
        ) {
            while ($index -lt $Text.Length -and $Text[$index] -notin "`r", "`n") {
                [void]$result.Append(' ')
                $index++
            }
            if ($index -lt $Text.Length) {
                [void]$result.Append($Text[$index])
            }
            continue
        }
        if (
            $Text[$index] -eq '/' -and
            $index + 1 -lt $Text.Length -and
            $Text[$index + 1] -eq '*'
        ) {
            $depth = 1
            [void]$result.Append('  ')
            $index += 2
            while ($index -lt $Text.Length -and $depth -gt 0) {
                if (
                    $Text[$index] -eq '/' -and
                    $index + 1 -lt $Text.Length -and
                    $Text[$index + 1] -eq '*'
                ) {
                    $depth++
                    [void]$result.Append('  ')
                    $index += 2
                    continue
                }
                if (
                    $Text[$index] -eq '*' -and
                    $index + 1 -lt $Text.Length -and
                    $Text[$index + 1] -eq '/'
                ) {
                    $depth--
                    [void]$result.Append('  ')
                    $index += 2
                    continue
                }
                [void]$result.Append(
                    $(if ($Text[$index] -in "`r", "`n") { $Text[$index] } else { ' ' })
                )
                $index++
            }
            if ($depth -ne 0) {
                throw 'SQL contains an unterminated block comment.'
            }
            $index--
            continue
        }
        if ($Text[$index] -eq '[') {
            [void]$result.Append('[')
            $index++
            $closed = $false
            while ($index -lt $Text.Length) {
                [void]$result.Append(
                    $(if ($MaskString -and $Text[$index] -ne ']') { ' ' } else { $Text[$index] })
                )
                if ($Text[$index] -ne ']') {
                    $index++
                    continue
                }
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq ']') {
                    [void]$result.Append($(if ($MaskString) { ' ' } else { ']' }))
                    $index += 2
                    continue
                }
                $closed = $true
                break
            }
            if (-not $closed) {
                throw 'SQL contains an unterminated bracket-quoted identifier.'
            }
            continue
        }
        if ($Text[$index] -eq '"') {
            [void]$result.Append('"')
            $index++
            $closed = $false
            while ($index -lt $Text.Length) {
                [void]$result.Append(
                    $(if ($MaskString -and $Text[$index] -ne '"') { ' ' } else { $Text[$index] })
                )
                if ($Text[$index] -ne '"') {
                    $index++
                    continue
                }
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq '"') {
                    [void]$result.Append($(if ($MaskString) { ' ' } else { '"' }))
                    $index += 2
                    continue
                }
                $closed = $true
                break
            }
            if (-not $closed) {
                throw 'SQL contains an unterminated quoted identifier.'
            }
            continue
        }
        if ($Text[$index] -eq "'") {
            [void]$result.Append($(if ($MaskString) { ' ' } else { "'" }))
            $index++
            $closed = $false
            while ($index -lt $Text.Length) {
                if ($Text[$index] -ne "'") {
                    [void]$result.Append(
                        $(if (
                            $MaskString -and
                            $Text[$index] -notin "`r", "`n"
                        ) { ' ' } else { $Text[$index] })
                    )
                    $index++
                    continue
                }
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq "'") {
                    [void]$result.Append($(if ($MaskString) { '  ' } else { "''" }))
                    $index += 2
                    continue
                }
                [void]$result.Append($(if ($MaskString) { ' ' } else { "'" }))
                $closed = $true
                break
            }
            if (-not $closed) {
                throw 'SQL contains an unterminated string literal.'
            }
            continue
        }
        [void]$result.Append($Text[$index])
    }
    return $result.ToString()
}

function ConvertTo-CodeOnly {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return ConvertTo-SqlLexicalView -Text $Text -MaskString
}

function ConvertTo-CommentFreeSql {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return ConvertTo-SqlLexicalView -Text $Text
}

function ConvertTo-SqlToken {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $tokens = [System.Collections.Generic.List[object]]::new()
    $index = 0
    while ($index -lt $Text.Length) {
        if ([char]::IsWhiteSpace($Text[$index])) {
            $index++
            continue
        }
        if ($Text[$index] -eq "'") {
            $start = $index
            $index++
            $literalValue = [Text.StringBuilder]::new()
            while ($index -lt $Text.Length) {
                if ($Text[$index] -ne "'") {
                    [void]$literalValue.Append($Text[$index])
                    $index++
                    continue
                }
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq "'") {
                    [void]$literalValue.Append("'")
                    $index += 2
                    continue
                }
                $index++
                break
            }
            $tokens.Add([pscustomobject]@{
                Kind = 'String'
                Value = '<STRING>'
                LiteralValue = $literalValue.ToString()
                Index = $start
                Length = $index - $start
            })
            continue
        }
        if ($Text[$index] -in '[', '"') {
            $start = $index
            $closing = if ($Text[$index] -eq '[') { ']' } else { '"' }
            $index++
            while ($index -lt $Text.Length) {
                if ($Text[$index] -ne $closing) {
                    $index++
                    continue
                }
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq $closing) {
                    $index += 2
                    continue
                }
                $index++
                break
            }
            $tokens.Add([pscustomobject]@{
                Kind = 'Identifier'
                Value = $Text.Substring($start, $index - $start)
                Index = $start
                Length = $index - $start
            })
            continue
        }
        if ($Text[$index] -match '[A-Za-z_@$#]') {
            $match = [regex]::Match(
                $Text.Substring($index),
                '^[A-Za-z_@$#][A-Za-z0-9_@$#]*'
            )
            $tokens.Add([pscustomobject]@{
                Kind = 'Word'
                Value = $match.Value.ToUpperInvariant()
                Index = $index
                Length = $match.Length
            })
            $index += $match.Length
            continue
        }
        $tokens.Add([pscustomobject]@{
            Kind = 'Symbol'
            Value = [string]$Text[$index]
            Index = $index
            Length = 1
        })
        $index++
    }
    return $tokens.ToArray()
}

function Get-SqlStatement {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$StartIndex
    )

    for ($index = $StartIndex; $index -lt $Text.Length; $index++) {
        if ($Text[$index] -eq "'") {
            $index++
            while ($index -lt $Text.Length) {
                if ($Text[$index] -ne "'") {
                    $index++
                    continue
                }
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq "'") {
                    $index += 2
                    continue
                }
                break
            }
            continue
        }
        if ($Text[$index] -in '[', '"') {
            $closing = if ($Text[$index] -eq '[') { ']' } else { '"' }
            $index++
            while ($index -lt $Text.Length) {
                if ($Text[$index] -ne $closing) {
                    $index++
                    continue
                }
                if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq $closing) {
                    $index += 2
                    continue
                }
                break
            }
            continue
        }
        if ($Text[$index] -eq ';') {
            return $Text.Substring($StartIndex, $index - $StartIndex + 1)
        }
    }
    return $Text.Substring($StartIndex)
}

function Read-SqlIdentifierPath {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $cursor = $StartIndex
    $parts = [System.Collections.Generic.List[string]]::new()
    $expectComponent = $true
    $consumedSyntax = $false
    $hasBoundaryWhitespace = $false
    while ($true) {
        $whitespaceStart = $cursor
        while ($cursor -lt $Text.Length -and [char]::IsWhiteSpace($Text[$cursor])) {
            $cursor++
        }
        $hadWhitespace = $cursor -gt $whitespaceStart
        if ($cursor -ge $Text.Length) {
            break
        }
        if ($expectComponent -and $Text[$cursor] -eq '.') {
            $parts.Add('')
            $consumedSyntax = $true
            $cursor++
            if ($parts.Count -ge 4) {
                return [pscustomobject]@{
                    Success = $false
                    Malformed = $true
                    Parts = @()
                    EndIndex = $cursor
                }
            }
            continue
        }
        if (-not $expectComponent) {
            if ($Text[$cursor] -ne '.') {
                $hasBoundaryWhitespace = $hadWhitespace
                break
            }
            $cursor++
            $expectComponent = $true
            $consumedSyntax = $true
            continue
        }

        $value = $null
        if ($Text[$cursor] -eq '[') {
            $cursor++
            $builder = [Text.StringBuilder]::new()
            $closed = $false
            while ($cursor -lt $Text.Length) {
                if ($Text[$cursor] -ne ']') {
                    [void]$builder.Append($Text[$cursor])
                    $cursor++
                    continue
                }
                if ($cursor + 1 -lt $Text.Length -and $Text[$cursor + 1] -eq ']') {
                    [void]$builder.Append(']')
                    $cursor += 2
                    continue
                }
                $cursor++
                $closed = $true
                break
            }
            if (-not $closed) {
                return [pscustomobject]@{
                    Success = $false
                    Malformed = $true
                    Parts = @()
                    EndIndex = $cursor
                }
            }
            $value = $builder.ToString()
        }
        elseif ($Text[$cursor] -eq '"') {
            $cursor++
            $builder = [Text.StringBuilder]::new()
            $closed = $false
            while ($cursor -lt $Text.Length) {
                if ($Text[$cursor] -ne '"') {
                    [void]$builder.Append($Text[$cursor])
                    $cursor++
                    continue
                }
                if ($cursor + 1 -lt $Text.Length -and $Text[$cursor + 1] -eq '"') {
                    [void]$builder.Append('"')
                    $cursor += 2
                    continue
                }
                $cursor++
                $closed = $true
                break
            }
            if (-not $closed) {
                return [pscustomobject]@{
                    Success = $false
                    Malformed = $true
                    Parts = @()
                    EndIndex = $cursor
                }
            }
            $value = $builder.ToString()
        }
        else {
            $identifier = [regex]::Match(
                $Text.Substring($cursor),
                '^[A-Za-z_][A-Za-z0-9_@$#]*'
            )
            if (-not $identifier.Success) {
                break
            }
            $value = $identifier.Value
            $cursor += $identifier.Length
        }
        $parts.Add($value)
        $consumedSyntax = $true
        $expectComponent = $false
        if ($parts.Count -ge 4) {
            $lookAhead = $cursor
            while ($lookAhead -lt $Text.Length -and [char]::IsWhiteSpace($Text[$lookAhead])) {
                $lookAhead++
            }
            if ($lookAhead -lt $Text.Length -and $Text[$lookAhead] -eq '.') {
                return [pscustomobject]@{
                    Success = $false
                    Malformed = $true
                    Parts = @()
                    EndIndex = $lookAhead
                }
            }
        }
    }
    $malformed = (
        $consumedSyntax -and
        (
            $expectComponent -or
            $parts.Count -eq 0 -or
            [string]::IsNullOrEmpty($parts[-1])
        )
    )
    if (-not $malformed -and $parts.Count -gt 0 -and $cursor -lt $Text.Length) {
        $malformed = (
            -not $hasBoundaryWhitespace -and
            -not [char]::IsWhiteSpace($Text[$cursor]) -and
            $Text[$cursor] -ne ';'
        )
    }
    return [pscustomobject]@{
        Success = $parts.Count -gt 0 -and -not $malformed
        Malformed = $malformed
        Parts = $parts.ToArray()
        EndIndex = $cursor
    }
}

function ConvertFrom-ConstantSqlExpression {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $cursor = $StartIndex
    $value = [Text.StringBuilder]::new()
    $literalCount = 0
    while ($true) {
        while ($cursor -lt $Text.Length -and [char]::IsWhiteSpace($Text[$cursor])) {
            $cursor++
        }
        if (
            $cursor + 1 -lt $Text.Length -and
            ($Text[$cursor] -eq 'N' -or $Text[$cursor] -eq 'n') -and
            $Text[$cursor + 1] -eq "'"
        ) {
            $cursor++
        }
        if ($cursor -ge $Text.Length -or $Text[$cursor] -ne "'") {
            return [pscustomobject]@{ Success = $false; Value = ''; EndIndex = $cursor }
        }
        $cursor++
        $closed = $false
        while ($cursor -lt $Text.Length) {
            if ($Text[$cursor] -ne "'") {
                [void]$value.Append($Text[$cursor])
                $cursor++
                continue
            }
            if ($cursor + 1 -lt $Text.Length -and $Text[$cursor + 1] -eq "'") {
                [void]$value.Append("'")
                $cursor += 2
                continue
            }
            $cursor++
            $closed = $true
            break
        }
        if (-not $closed) {
            return [pscustomobject]@{ Success = $false; Value = ''; EndIndex = $cursor }
        }
        $literalCount++
        while ($cursor -lt $Text.Length -and [char]::IsWhiteSpace($Text[$cursor])) {
            $cursor++
        }
        if ($cursor -ge $Text.Length -or $Text[$cursor] -ne '+') {
            break
        }
        $cursor++
    }
    return [pscustomobject]@{
        Success = $literalCount -gt 0
        Value = $value.ToString()
        EndIndex = $cursor
    }
}

function Test-ConstantDynamicDdl {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $tokens = @(ConvertTo-SqlToken -Text (ConvertTo-CodeOnly -Text $Text))
    return @(
        $tokens |
            Where-Object {
                $_.Kind -eq 'Word' -and
                $_.Value -in @('CREATE', 'ALTER', 'DROP', 'TRUNCATE')
            }
    ).Count -gt 0
}

function Get-SqlCanonicalTokenText {
    param(
        [Parameter(Mandatory)][object[]]$Tokens,
        [Parameter(Mandatory)][int]$StartIndex,
        [Parameter(Mandatory)][int]$EndIndex
    )

    $values = for ($index = $StartIndex; $index -le $EndIndex; $index++) {
        $token = $Tokens[$index]
        if ($token.Kind -ne 'Identifier') {
            $token.Value
            continue
        }
        $value = [string]$token.Value
        if ($value[0] -eq '[') {
            $value = $value.Substring(1, $value.Length - 2).Replace(']]', ']')
        }
        else {
            $value = $value.Substring(1, $value.Length - 2).Replace('""', '"')
        }
        if ($value -notmatch '^[A-Za-z_][A-Za-z0-9_@$#]*$') {
            '<INVALID_IDENTIFIER>'
        }
        else {
            $value.ToUpperInvariant()
        }
    }
    return $values -join ' '
}

function Get-SqlCanonicalTokenValue {
    param([Parameter(Mandatory)][object]$Token)

    if ($Token.Kind -ne 'Identifier') {
        return ([string]$Token.Value).ToUpperInvariant()
    }
    $value = [string]$Token.Value
    if ($value[0] -eq '[') {
        return $value.Substring(1, $value.Length - 2).Replace(']]', ']').ToUpperInvariant()
    }
    return $value.Substring(1, $value.Length - 2).Replace('""', '"').ToUpperInvariant()
}

function Test-SqlDestructiveProcedureName {
    param([Parameter(Mandatory)][string]$Name)

    $canonicalName = $Name.ToLowerInvariant()
    return (
        $canonicalName -match '^sp_(?:delete|drop|remove|revoke)' -or
        $canonicalName -match '^sp_(?:detach|rename)'
    )
}

function Test-SqlUnsupportedInstanceMutation {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $tokens = @(ConvertTo-SqlToken -Text (ConvertTo-CodeOnly -Text $Text))
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        if (
            $tokens[$index].Kind -eq 'Word' -and
            $tokens[$index].Value -in @('GRANT', 'DENY', 'REVOKE')
        ) {
            return $true
        }
        if (
            $tokens[$index].Kind -ne 'Word' -or
            $tokens[$index].Value -ne 'SELECT'
        ) {
            continue
        }
        for ($cursor = $index + 1; $cursor -lt $tokens.Count; $cursor++) {
            if (
                $tokens[$cursor].Kind -eq 'Symbol' -and
                $tokens[$cursor].Value -eq ';'
            ) {
                break
            }
            if (
                $tokens[$cursor].Kind -eq 'Word' -and
                $tokens[$cursor].Value -eq 'INTO'
            ) {
                return $true
            }
        }
    }
    return $false
}

function Get-SqlBareProcedureInvocation {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $codeOnly = ConvertTo-CodeOnly -Text $Text
    $commentFree = ConvertTo-CommentFreeSql -Text $Text

    $invocations = [System.Collections.Generic.List[object]]::new()
    foreach ($batch in @(Get-SqlBatch -Text $Text)) {
        $cursor = $batch.StartIndex
        $batchEnd = $batch.EndIndex
        while (
            $cursor -lt $batchEnd -and
            (
                [char]::IsWhiteSpace($codeOnly[$cursor]) -or
                $codeOnly[$cursor] -eq ';'
            )
        ) {
            $cursor++
        }
        if ($cursor -ge $batchEnd) {
            continue
        }
        $procedure = Read-SqlIdentifierPath -Text $commentFree -StartIndex $cursor
        if (-not $procedure.Success) {
            continue
        }
        $procedureName = $procedure.Parts[-1].ToLowerInvariant()
        if (
            $procedure.Parts.Count -eq 1 -and
            $procedureName.ToUpperInvariant() -in @(
                'ALTER',
                'BACKUP',
                'BEGIN',
                'CREATE',
                'DBCC',
                'DECLARE',
                'DELETE',
                'DENY',
                'DROP',
                'EXEC',
                'EXECUTE',
                'GRANT',
                'IF',
                'INSERT',
                'MERGE',
                'PRINT',
                'RAISERROR',
                'RESTORE',
                'RETURN',
                'REVOKE',
                'SELECT',
                'SET',
                'THROW',
                'TRUNCATE',
                'UPDATE',
                'USE',
                'WAITFOR',
                'WHILE',
                'WITH'
            )
        ) {
            continue
        }
        $statement = Get-SqlStatement -Text $commentFree -StartIndex $cursor
        $invocations.Add([pscustomobject]@{
            Index = $cursor
            ProcedureName = $procedureName
            Statement = $statement
        })
    }
    return $invocations.ToArray()
}

function Get-SqlManagedBatchParserTypes {
    if ($script:ManagedBatchParserTypes) {
        return $script:ManagedBatchParserTypes
    }

    $moduleCandidates = @(
        Get-Module -ListAvailable -Name SqlServer |
            Where-Object Version -eq $script:SqlServerModuleVersion |
            Sort-Object ModuleBase
    )
    if ($moduleCandidates.Count -eq 0) {
        throw (
            "The pinned SqlServer PowerShell module $script:SqlServerModuleVersion is " +
            'required for deterministic SQL batch parsing.'
        )
    }

    $assemblyRelativePath = if ($PSVersionTable.PSEdition -eq 'Core') {
        [IO.Path]::Combine('coreclr', 'Microsoft.SqlTools.ManagedBatchParser.dll')
    }
    else {
        'Microsoft.SqlTools.ManagedBatchParser.dll'
    }
    $assemblyPaths = @(
        $moduleCandidates |
            ForEach-Object {
                [IO.Path]::GetFullPath(
                    [IO.Path]::Combine($_.ModuleBase, $assemblyRelativePath)
                )
            } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    )
    if ($assemblyPaths.Count -eq 0) {
        throw (
            'The pinned SqlServer module does not contain the expected managed batch ' +
            'parser assembly.'
        )
    }

    $assembly = @(
        [AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object {
                $_.GetName().Name -eq 'Microsoft.SqlTools.ManagedBatchParser'
            }
    ) | Select-Object -First 1
    if ($assembly) {
        $loadedPath = [IO.Path]::GetFullPath($assembly.Location)
        if ($loadedPath -notin $assemblyPaths) {
            throw (
                'A managed batch parser from outside pinned SqlServer module ' +
                "$script:SqlServerModuleVersion is already loaded."
            )
        }
    }
    else {
        Import-Module `
            -Name $moduleCandidates[0].Path `
            -Scope Local `
            -Force `
            -ErrorAction Stop
        $assembly = @(
            [AppDomain]::CurrentDomain.GetAssemblies() |
                Where-Object {
                    $_.GetName().Name -eq 'Microsoft.SqlTools.ManagedBatchParser' -and
                    [IO.Path]::GetFullPath($_.Location) -in $assemblyPaths
                }
        ) | Select-Object -First 1
    }
    if (-not $assembly) {
        throw (
            'Failed to load the managed batch parser from pinned SqlServer module ' +
            "$script:SqlServerModuleVersion."
        )
    }

    $wrapperType = $assembly.GetType(
        'Microsoft.SqlTools.ServiceLayer.BatchParser.BatchParserWrapper',
        $false
    )
    $conditionsType = $assembly.GetType(
        'Microsoft.SqlTools.ServiceLayer.BatchParser.ExecutionEngineCode.ExecutionEngineConditions',
        $false
    )
    if (
        -not $wrapperType -or
        -not $conditionsType -or
        -not $wrapperType.GetMethod(
            'GetBatches',
            [type[]]@([string], $conditionsType)
        )
    ) {
        throw 'The pinned managed batch parser API has an unsupported shape.'
    }

    $script:ManagedBatchParserTypes = [pscustomobject]@{
        Wrapper = $wrapperType
        Conditions = $conditionsType
    }
    return $script:ManagedBatchParserTypes
}

function Get-SqlBatch {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $types = Get-SqlManagedBatchParserTypes
    $parser = [Activator]::CreateInstance($types.Wrapper)
    try {
        $conditions = [Activator]::CreateInstance($types.Conditions)
        # SQLCMD directives and variables are resolved by the stricter repository
        # converter before this parser runs. Disable its second variable-expansion pass
        # while retaining the same pinned GO grammar through BatchSeparator.
        $conditions.IsSqlCmd = $false
        $conditions.BatchSeparator = 'GO'
        try {
            $parsedBatches = @($parser.GetBatches($Text, $conditions))
        }
        catch {
            throw [InvalidOperationException]::new(
                (
                    'SQL batch parsing failed through pinned SqlServer module ' +
                    "$script:SqlServerModuleVersion."
                ),
                $_.Exception.GetBaseException()
            )
        }
    }
    finally {
        if ($parser) {
            $parser.Dispose()
        }
    }

    $batches = [System.Collections.Generic.List[object]]::new()
    $searchIndex = 0
    $batchIndex = 0
    foreach ($parsedBatch in $parsedBatches) {
        $batchText = [string]$parsedBatch.BatchText
        $startIndex = $Text.IndexOf(
            $batchText,
            $searchIndex,
            [StringComparison]::Ordinal
        )
        if ($startIndex -lt 0) {
            throw 'The pinned managed batch parser returned an unmappable batch.'
        }
        $endIndex = $startIndex + $batchText.Length
        $batches.Add([pscustomobject]@{
            BatchIndex = $batchIndex
            Text = $batchText
            StartIndex = $startIndex
            EndIndex = $endIndex
            StartLine = [int]$parsedBatch.StartLine
            BatchExecutionCount = [int]$parsedBatch.BatchExecutionCount
        })
        $searchIndex = $endIndex
        $batchIndex++
    }
    return $batches.ToArray()
}

function Get-SqlBatchNumber {
    param(
        [Parameter(Mandatory)][object[]]$Batches,
        [Parameter(Mandatory)][int]$TextIndex
    )

    foreach ($batch in $Batches) {
        if ($TextIndex -ge $batch.StartIndex -and $TextIndex -lt $batch.EndIndex) {
            return $batch.BatchIndex
        }
    }
    return -1
}

function Test-SqlDynamicExecution {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateRange(0, 8)][int]$Depth = 0
    )

    if ($Depth -ge 8) {
        return $false
    }
    foreach ($bareInvocation in @(Get-SqlBareProcedureInvocation -Text $Text)) {
        if (
            -not (
                Test-SqlDynamicExecution `
                    -Text "EXEC $($bareInvocation.Statement)" `
                    -Depth ($Depth + 1)
            )
        ) {
            return $false
        }
    }
    $codeOnly = ConvertTo-CodeOnly -Text $Text
    $commentFree = ConvertTo-CommentFreeSql -Text $Text
    foreach ($executeMatch in [regex]::Matches($codeOnly, '(?is)\bEXEC(?:UTE)?\b')) {
        $statement = Get-SqlStatement -Text $commentFree -StartIndex $executeMatch.Index
        $cursor = $executeMatch.Length
        while ($cursor -lt $statement.Length -and [char]::IsWhiteSpace($statement[$cursor])) {
            $cursor++
        }
        $returnAssignment = [regex]::Match(
            $statement.Substring($cursor),
            '^(?is)@[A-Za-z_][A-Za-z0-9_]*\s*=\s*'
        )
        if ($returnAssignment.Success) {
            $cursor += $returnAssignment.Length
        }
        $parenthesized = $cursor -lt $statement.Length -and $statement[$cursor] -eq '('
        if ($parenthesized) {
            $cursor++
            while ($cursor -lt $statement.Length -and [char]::IsWhiteSpace($statement[$cursor])) {
                $cursor++
            }
        }
        $startsWithLiteral = (
            $cursor -lt $statement.Length -and $statement[$cursor] -eq "'"
        ) -or (
            $cursor + 1 -lt $statement.Length -and
            ($statement[$cursor] -eq 'N' -or $statement[$cursor] -eq 'n') -and
            $statement[$cursor + 1] -eq "'"
        )
        $startsWithVariable = $cursor -lt $statement.Length -and $statement[$cursor] -eq '@'
        $procedure = [pscustomobject]@{
            Success = $false
            Malformed = $false
            Parts = @()
            EndIndex = $cursor
        }
        if (-not $parenthesized -and -not $startsWithLiteral -and -not $startsWithVariable) {
            $procedure = Read-SqlIdentifierPath -Text $statement -StartIndex $cursor
            if (-not $procedure.Success) {
                return $false
            }
        }
        $procedureName = if ($procedure.Success) {
            $procedure.Parts[-1].ToLowerInvariant()
        }
        else {
            ''
        }
        if (
            $procedureName -and
            (Test-SqlDestructiveProcedureName -Name $procedureName)
        ) {
            return $false
        }
        $isSpExecuteSql = $procedureName -eq 'sp_executesql'
        if ($isSpExecuteSql) {
            $cursor = $procedure.EndIndex
            while ($cursor -lt $statement.Length -and [char]::IsWhiteSpace($statement[$cursor])) {
                $cursor++
            }
            $namedStatement = [regex]::Match(
                $statement.Substring($cursor),
                '^(?is)@stmt\s*=\s*'
            )
            if ($namedStatement.Success) {
                $cursor += $namedStatement.Length
            }
        }
        if (
            -not $parenthesized -and
            -not $isSpExecuteSql -and
            -not $startsWithLiteral -and
            -not $startsWithVariable
        ) {
            continue
        }

        $expression = ConvertFrom-ConstantSqlExpression -Text $statement -StartIndex $cursor
        if (-not $expression.Success) {
            return $false
        }
        $afterExpression = $expression.EndIndex
        while (
            $afterExpression -lt $statement.Length -and
            [char]::IsWhiteSpace($statement[$afterExpression])
        ) {
            $afterExpression++
        }
        if (
            $parenthesized -and
            ($afterExpression -ge $statement.Length -or $statement[$afterExpression] -ne ')')
        ) {
            return $false
        }
        if (Test-ConstantDynamicDdl -Text $expression.Value) {
            return $false
        }
        if (Test-SqlUnsupportedInstanceMutation -Text $expression.Value) {
            return $false
        }
        if (-not (Test-SqlDynamicExecution -Text $expression.Value -Depth ($Depth + 1))) {
            return $false
        }
    }
    return $true
}

function Get-SqlBlockEndIndex {
    param(
        [Parameter(Mandatory)][object[]]$Tokens,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $blockDepth = 0
    $caseDepth = 0
    for ($cursor = $StartIndex; $cursor -lt $Tokens.Count; $cursor++) {
        if ($Tokens[$cursor].Kind -ne 'Word') {
            continue
        }
        $value = $Tokens[$cursor].Value
        if ($value -eq 'CASE') {
            $caseDepth++
            continue
        }
        if ($value -eq 'BEGIN') {
            $nextWord = if (
                $cursor + 1 -lt $Tokens.Count -and
                $Tokens[$cursor + 1].Kind -eq 'Word'
            ) {
                $Tokens[$cursor + 1].Value
            }
            else {
                ''
            }
            if (
                $nextWord -notin @(
                    'CONVERSATION',
                    'DIALOG',
                    'DISTRIBUTED',
                    'TRAN',
                    'TRANSACTION'
                )
            ) {
                $blockDepth++
            }
            continue
        }
        if ($value -ne 'END') {
            continue
        }
        if ($caseDepth -gt 0) {
            $caseDepth--
            continue
        }
        if (
            $cursor + 1 -lt $Tokens.Count -and
            $Tokens[$cursor + 1].Kind -eq 'Word' -and
            $Tokens[$cursor + 1].Value -eq 'CONVERSATION'
        ) {
            continue
        }
        $blockDepth--
        if ($blockDepth -eq 0) {
            return $cursor
        }
    }
    return -1
}

function Test-SqlReadOnlySelectTokenStream {
    param(
        [Parameter(Mandatory)][object[]]$Tokens,
        [switch]$DisallowVariableAssignment
    )

    $blockedWords = @(
        'ALTER',
        'BACKUP',
        'BULK',
        'CHECKPOINT',
        'CREATE',
        'DBCC',
        'DELETE',
        'DENY',
        'DISABLE',
        'DROP',
        'ENABLE',
        'EXEC',
        'EXECUTE',
        'GRANT',
        'INSERT',
        'INTO',
        'KILL',
        'MERGE',
        'OPENDATASOURCE',
        'OPENQUERY',
        'OPENROWSET',
        'RECONFIGURE',
        'RESTORE',
        'REVOKE',
        'SET',
        'SHUTDOWN',
        'TRUNCATE',
        'UPDATE',
        'USE',
        'WAITFOR'
    )
    $cursor = 0
    $statementCount = 0
    while ($cursor -lt $Tokens.Count) {
        while (
            $cursor -lt $Tokens.Count -and
            $Tokens[$cursor].Kind -eq 'Symbol' -and
            $Tokens[$cursor].Value -eq ';'
        ) {
            $cursor++
        }
        if ($cursor -ge $Tokens.Count) {
            break
        }
        if (
            $Tokens[$cursor].Kind -ne 'Word' -or
            $Tokens[$cursor].Value -ne 'SELECT'
        ) {
            return $false
        }
        $statementCount++
        $cursor++
        while ($cursor -lt $Tokens.Count) {
            $token = $Tokens[$cursor]
            if ($token.Kind -eq 'Symbol' -and $token.Value -eq ';') {
                $cursor++
                break
            }
            if ($token.Kind -eq 'Word' -and $token.Value -in $blockedWords) {
                return $false
            }
            if (
                $token.Kind -eq 'Word' -and
                $token.Value -eq 'NEXT' -and
                $cursor + 2 -lt $Tokens.Count -and
                $Tokens[$cursor + 1].Kind -eq 'Word' -and
                $Tokens[$cursor + 1].Value -eq 'VALUE' -and
                $Tokens[$cursor + 2].Kind -eq 'Word' -and
                $Tokens[$cursor + 2].Value -eq 'FOR'
            ) {
                return $false
            }
            if (
                $DisallowVariableAssignment -and
                $token.Kind -eq 'Word' -and
                $token.Value.StartsWith('@') -and
                $cursor + 1 -lt $Tokens.Count -and
                $Tokens[$cursor + 1].Kind -eq 'Symbol' -and
                $Tokens[$cursor + 1].Value -eq '='
            ) {
                return $false
            }
            $cursor++
        }
    }
    return $statementCount -gt 0
}

function Test-SqlInstanceStatementSequence {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][object[]]$Tokens,
        [Parameter(Mandatory)][ref]$Cursor,
        [switch]$StopAtEnd,
        [switch]$GuardBody
    )

    $supportedProcedures = @(
        'sp_add_job',
        'sp_update_job',
        'sp_add_jobstep',
        'sp_update_jobstep',
        'sp_add_jobserver'
    )
    $statementCount = 0
    while ($Cursor.Value -lt $Tokens.Count) {
        while (
            $Cursor.Value -lt $Tokens.Count -and
            $Tokens[$Cursor.Value].Kind -eq 'Symbol' -and
            $Tokens[$Cursor.Value].Value -eq ';'
        ) {
            $Cursor.Value++
        }
        if ($Cursor.Value -ge $Tokens.Count) {
            return -not $StopAtEnd
        }
        $start = $Cursor.Value
        $startValue = Get-SqlCanonicalTokenValue -Token $Tokens[$start]
        if ($startValue -eq 'END') {
            if (-not $StopAtEnd) {
                return $false
            }
            $Cursor.Value++
            return -not $GuardBody -or $statementCount -gt 0
        }
        if ($startValue -eq 'IF') {
            if ($GuardBody) {
                return $false
            }
            $cursorIndex = $start + 1
            if (
                $cursorIndex -lt $Tokens.Count -and
                (Get-SqlCanonicalTokenValue -Token $Tokens[$cursorIndex]) -eq 'NOT'
            ) {
                $cursorIndex++
            }
            if (
                $cursorIndex -ge $Tokens.Count -or
                (Get-SqlCanonicalTokenValue -Token $Tokens[$cursorIndex]) -ne 'EXISTS'
            ) {
                return $false
            }
            $cursorIndex++
            if (
                $cursorIndex -ge $Tokens.Count -or
                $Tokens[$cursorIndex].Kind -ne 'Symbol' -or
                $Tokens[$cursorIndex].Value -ne '('
            ) {
                return $false
            }
            $predicateStart = ++$cursorIndex
            $parenthesisDepth = 1
            while ($cursorIndex -lt $Tokens.Count -and $parenthesisDepth -gt 0) {
                if ($Tokens[$cursorIndex].Kind -eq 'Symbol') {
                    if ($Tokens[$cursorIndex].Value -eq '(') {
                        $parenthesisDepth++
                    }
                    elseif ($Tokens[$cursorIndex].Value -eq ')') {
                        $parenthesisDepth--
                    }
                }
                $cursorIndex++
            }
            if ($parenthesisDepth -ne 0) {
                return $false
            }
            $predicateEnd = $cursorIndex - 2
            if (
                $predicateEnd -lt $predicateStart -or
                -not (
                    Test-SqlReadOnlySelectTokenStream `
                        -Tokens @($Tokens[$predicateStart..$predicateEnd])
                )
            ) {
                return $false
            }
            if (
                $cursorIndex -ge $Tokens.Count -or
                (Get-SqlCanonicalTokenValue -Token $Tokens[$cursorIndex]) -ne 'BEGIN'
            ) {
                return $false
            }
            $Cursor.Value = $cursorIndex + 1
            if (
                -not (
                    Test-SqlInstanceStatementSequence `
                        -Text $Text `
                        -Tokens $Tokens `
                        -Cursor $Cursor `
                        -StopAtEnd `
                        -GuardBody
                )
            ) {
                return $false
            }
            if (
                $Cursor.Value -lt $Tokens.Count -and
                (Get-SqlCanonicalTokenValue -Token $Tokens[$Cursor.Value]) -eq 'ELSE'
            ) {
                $Cursor.Value++
                if (
                    $Cursor.Value -ge $Tokens.Count -or
                    (Get-SqlCanonicalTokenValue -Token $Tokens[$Cursor.Value]) -ne 'BEGIN'
                ) {
                    return $false
                }
                $Cursor.Value++
                if (
                    -not (
                        Test-SqlInstanceStatementSequence `
                            -Text $Text `
                            -Tokens $Tokens `
                            -Cursor $Cursor `
                            -StopAtEnd `
                            -GuardBody
                    )
                ) {
                    return $false
                }
            }
            continue
        }
        if ($GuardBody -and $startValue -notin @('CREATE', 'EXEC', 'EXECUTE')) {
            return $false
        }

        $end = $start
        while (
            $end -lt $Tokens.Count -and
            -not (
                $Tokens[$end].Kind -eq 'Symbol' -and
                $Tokens[$end].Value -eq ';'
            )
        ) {
            if ((Get-SqlCanonicalTokenValue -Token $Tokens[$end]) -eq 'END') {
                return $false
            }
            $end++
        }
        if ($end -ge $Tokens.Count) {
            return $false
        }
        $statementTokens = @($Tokens[$start..$end])
        $statementValues = @(
            $statementTokens |
                ForEach-Object { Get-SqlCanonicalTokenValue -Token $_ }
        )
        switch ($startValue) {
            'USE' {
                if (
                    $statementValues.Count -ne 3 -or
                    $statementValues[1] -notin @('MASTER', 'MSDB')
                ) {
                    return $false
                }
            }
            'DECLARE' {
                $shape = $statementValues -join '|'
                if (
                    $shape -notin @(
                        'DECLARE|@JOBNAME|SYSNAME|=|N|<STRING>|;',
                        'DECLARE|@OWNERLOGINNAME|SYSNAME|=|N|<STRING>|;',
                        'DECLARE|@STEPNAME|SYSNAME|=|N|<STRING>|;',
                        'DECLARE|@LOCALSERVERNAME|SYSNAME|=|N|<STRING>|;'
                    )
                ) {
                    return $false
                }
            }
            'CREATE' {
                if (-not $GuardBody) {
                    return $false
                }
                if (
                    $statementValues.Count -ne 7 -or
                    $statementValues[1] -ne 'LOGIN' -or
                    $statementTokens[2].Kind -ne 'Identifier' -or
                    ($statementValues[3..6] -join '|') -cne 'FROM|EXTERNAL|PROVIDER|;'
                ) {
                    return $false
                }
            }
            { $_ -in @('EXEC', 'EXECUTE') } {
                if (-not $GuardBody) {
                    return $false
                }
                $procedure = Get-SqlProcedureInvocationDetail `
                    -Text $Text `
                    -ExecuteIndex $Tokens[$start].Index
                if (-not $procedure.Success) {
                    return $false
                }
                if (
                    $procedure.Dynamic -or
                    $procedure.Name -notin $supportedProcedures -or
                    ($procedure.Parts -join '.').ToLowerInvariant() -cne
                        "msdb.dbo.$($procedure.Name)"
                ) {
                    return $false
                }
            }
            default {
                return $false
            }
        }
        $Cursor.Value = $end + 1
        $statementCount++
    }
    return -not $StopAtEnd
}

function Test-SqlInstanceStatementAllowlist {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    foreach ($batch in @(Get-SqlBatch -Text $Text)) {
        $commentFree = ConvertTo-CommentFreeSql -Text $batch.Text
        $tokens = @(ConvertTo-SqlToken -Text $commentFree)
        $cursor = 0
        if (
            -not (
                Test-SqlInstanceStatementSequence `
                    -Text $commentFree `
                    -Tokens $tokens `
                    -Cursor ([ref]$cursor)
            )
        ) {
            return $false
        }
    }
    return $true
}

function Test-SqlInstanceGuardCoverage {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if (-not (Test-SqlInstanceStatementAllowlist -Text $Text)) {
        return $false
    }
    $commentFree = ConvertTo-CommentFreeSql -Text $Text
    $tokens = @(ConvertTo-SqlToken -Text $commentFree)
    $sqlBatches = @(Get-SqlBatch -Text $Text)
    $bareMutationIndices = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($bareInvocation in @(Get-SqlBareProcedureInvocation -Text $Text)) {
        [void]$bareMutationIndices.Add($bareInvocation.Index)
    }
    $procedureRanges = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        if (
            $tokens[$index].Kind -ne 'Word' -or
            $tokens[$index].Value -notin @('EXEC', 'EXECUTE')
        ) {
            continue
        }
        $procedure = Get-SqlProcedureInvocationDetail `
            -Text $commentFree `
            -ExecuteIndex $tokens[$index].Index
        if ($procedure.Success -and -not $procedure.Dynamic) {
            $procedureRanges.Add([pscustomobject]@{
                Start = $procedure.ProcedureStartIndex
                End = $procedure.ProcedureEndIndex
                Name = $procedure.Name.ToUpperInvariant()
            })
        }
    }
    $supportedProcedures = @(
        'SP_ADD_JOB',
        'SP_UPDATE_JOB',
        'SP_ADD_JOBSTEP',
        'SP_UPDATE_JOBSTEP',
        'SP_ADD_JOBSERVER'
    )
    foreach ($token in $tokens) {
        if ($token.Kind -notin @('Word', 'Identifier')) {
            continue
        }
        $name = Get-SqlCanonicalTokenValue -Token $token
        if (
            -not $name.StartsWith('SP_') -and
            $name -notin $supportedProcedures -and
            -not (Test-SqlDestructiveProcedureName -Name $name)
        ) {
            continue
        }
        $isExecutedProcedure = @(
            $procedureRanges |
                Where-Object {
                    $_.Name -ceq $name -and
                    $token.Index -ge $_.Start -and
                    $token.Index -lt $_.End
                }
        ).Count -gt 0
        if (-not $isExecutedProcedure) {
            return $false
        }
    }
    $guardRanges = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        if ($tokens[$index].Kind -ne 'Word' -or $tokens[$index].Value -ne 'IF') {
            continue
        }
        $cursor = $index + 1
        $isNotExists = $false
        if (
            $cursor -lt $tokens.Count -and
            $tokens[$cursor].Kind -eq 'Word' -and
            $tokens[$cursor].Value -eq 'NOT'
        ) {
            $isNotExists = $true
            $cursor++
        }
        if (
            $cursor -lt $tokens.Count -and
            $tokens[$cursor].Kind -eq 'Word' -and
            $tokens[$cursor].Value -eq 'EXISTS'
        ) {
            $cursor++
            if (
                $cursor -lt $tokens.Count -and
                $tokens[$cursor].Kind -eq 'Symbol' -and
                $tokens[$cursor].Value -eq '('
            ) {
                $parenthesisDepth = 0
                while ($cursor -lt $tokens.Count) {
                    if (
                        $tokens[$cursor].Kind -eq 'Symbol' -and
                        $tokens[$cursor].Value -eq '('
                    ) {
                        $parenthesisDepth++
                    }
                    elseif (
                        $tokens[$cursor].Kind -eq 'Symbol' -and
                        $tokens[$cursor].Value -eq ')'
                    ) {
                        $parenthesisDepth--
                        if ($parenthesisDepth -eq 0) {
                            $cursor++
                            break
                        }
                    }
                    $cursor++
                }
            }
            if ($cursor -ge $tokens.Count) {
                continue
            }
            if (
                $tokens[$cursor].Kind -ne 'Word' -or
                $tokens[$cursor].Value -ne 'BEGIN'
            ) {
                continue
            }

            $rangeStart = $cursor
            $rangeEnd = Get-SqlBlockEndIndex -Tokens $tokens -StartIndex $cursor
            if ($rangeEnd -lt 0) {
                continue
            }
            $predicate = Get-SqlCanonicalTokenText `
                -Tokens $tokens `
                -StartIndex $index `
                -EndIndex ($rangeStart - 1)
            $predicateText = $commentFree.Substring(
                $tokens[$index].Index,
                $tokens[$rangeStart].Index - $tokens[$index].Index
            )
            $batch = Get-SqlBatchNumber `
                -Batches $sqlBatches `
                -TextIndex $tokens[$index].Index
            $guardRanges.Add([pscustomobject]@{
                Start = $rangeStart
                End = $rangeEnd
                Branch = 'If'
                IsNotExists = $isNotExists
                Predicate = $predicate
                PredicateText = $predicateText
                Batch = $batch
            })
            $cursor = $rangeEnd + 1
            while (
                $cursor -lt $tokens.Count -and
                $tokens[$cursor].Kind -eq 'Symbol' -and
                $tokens[$cursor].Value -eq ';'
            ) {
                $cursor++
            }
            if (
                $cursor -lt $tokens.Count -and
                $tokens[$cursor].Kind -eq 'Word' -and
                $tokens[$cursor].Value -eq 'ELSE'
            ) {
                $cursor++
                while (
                    $cursor -lt $tokens.Count -and
                    $tokens[$cursor].Kind -eq 'Symbol' -and
                    $tokens[$cursor].Value -eq ';'
                ) {
                    $cursor++
                }
                if (
                    $cursor -lt $tokens.Count -and
                    $tokens[$cursor].Kind -eq 'Word' -and
                    $tokens[$cursor].Value -eq 'BEGIN'
                ) {
                    $elseEnd = Get-SqlBlockEndIndex -Tokens $tokens -StartIndex $cursor
                    if ($elseEnd -lt 0) {
                        continue
                    }
                    $guardRanges.Add([pscustomobject]@{
                        Start = $cursor
                        End = $elseEnd
                        Branch = 'Else'
                        IsNotExists = $isNotExists
                        Predicate = $predicate
                        PredicateText = $predicateText
                        Batch = $batch
                    })
                }
            }
        }
    }
    if ($guardRanges.Count -eq 0) {
        return $false
    }

    $mutationVerbs = @(
        'CREATE',
        'ALTER',
        'DROP',
        'TRUNCATE',
        'INSERT',
        'UPDATE',
        'DELETE',
        'MERGE',
        'GRANT',
        'DENY',
        'REVOKE',
        'EXEC',
        'EXECUTE'
    )
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $isMutationVerb = (
            $tokens[$index].Kind -eq 'Word' -and
            $tokens[$index].Value -in $mutationVerbs
        )
        if (-not $isMutationVerb -and -not $bareMutationIndices.Contains($tokens[$index].Index)) {
            continue
        }
        $mutationBatch = Get-SqlBatchNumber `
            -Batches $sqlBatches `
            -TextIndex $tokens[$index].Index
        $isGuarded = @(
            $guardRanges |
                Where-Object {
                    $_.Batch -eq $mutationBatch -and
                    $index -ge $_.Start -and
                    $index -le $_.End
                }
        ).Count -gt 0
        if (-not $isGuarded) {
            return $false
        }
        $guard = @(
            $guardRanges |
                Where-Object {
                    $_.Batch -eq $mutationBatch -and
                    $index -ge $_.Start -and
                    $index -le $_.End
                } |
                Sort-Object Start -Descending
        )[0]
        if (
            -not (
                Test-SqlInstanceMutationCorrelation `
                    -Text $commentFree `
                    -Tokens $tokens `
                    -MutationIndex $index `
                    -Guard $guard
            )
        ) {
            return $false
        }
    }
    return $true
}

function Get-SqlProcedureInvocationDetail {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$ExecuteIndex
    )

    $statement = Get-SqlStatement -Text $Text -StartIndex $ExecuteIndex
    $execute = [regex]::Match($statement, '^(?is)EXEC(?:UTE)?\b')
    if (-not $execute.Success) {
        return [pscustomobject]@{ Success = $false; Dynamic = $false; Name = ''; Statement = $statement }
    }
    $cursor = $execute.Length
    while ($cursor -lt $statement.Length -and [char]::IsWhiteSpace($statement[$cursor])) {
        $cursor++
    }
    $assignment = [regex]::Match(
        $statement.Substring($cursor),
        '^(?is)@[A-Za-z_][A-Za-z0-9_]*\s*=\s*'
    )
    if ($assignment.Success) {
        $cursor += $assignment.Length
    }
    $parenthesized = $cursor -lt $statement.Length -and $statement[$cursor] -eq '('
    if ($parenthesized) {
        $cursor++
        while ($cursor -lt $statement.Length -and [char]::IsWhiteSpace($statement[$cursor])) {
            $cursor++
        }
    }
    $startsWithLiteral = (
        $cursor -lt $statement.Length -and $statement[$cursor] -eq "'"
    ) -or (
        $cursor + 1 -lt $statement.Length -and
        $statement[$cursor] -in 'N', 'n' -and
        $statement[$cursor + 1] -eq "'"
    )
    $startsWithVariable = $cursor -lt $statement.Length -and $statement[$cursor] -eq '@'
    if ($parenthesized -or $startsWithLiteral -or $startsWithVariable) {
        $expression = ConvertFrom-ConstantSqlExpression -Text $statement -StartIndex $cursor
        return [pscustomobject]@{
            Success = $expression.Success
            Dynamic = $true
            Name = ''
            Parts = @()
            Statement = $statement
            Arguments = $statement.Substring($cursor)
            Expression = $expression.Value
        }
    }
    $procedureStart = $cursor
    $procedure = Read-SqlIdentifierPath -Text $statement -StartIndex $cursor
    if (-not $procedure.Success) {
        return [pscustomobject]@{ Success = $false; Dynamic = $false; Name = ''; Statement = $statement }
    }
    $name = $procedure.Parts[-1].ToLowerInvariant()
    if ($name -eq 'sp_executesql') {
        $cursor = $procedure.EndIndex
        while ($cursor -lt $statement.Length -and [char]::IsWhiteSpace($statement[$cursor])) {
            $cursor++
        }
        $namedStatement = [regex]::Match($statement.Substring($cursor), '^(?is)@stmt\s*=\s*')
        if ($namedStatement.Success) {
            $cursor += $namedStatement.Length
        }
        $expression = ConvertFrom-ConstantSqlExpression -Text $statement -StartIndex $cursor
        return [pscustomobject]@{
            Success = $expression.Success
            Dynamic = $true
            Name = $name
            Parts = $procedure.Parts
            Statement = $statement
            Arguments = $statement.Substring($procedure.EndIndex)
            Expression = $expression.Value
            ProcedureStartIndex = $ExecuteIndex + $procedureStart
            ProcedureEndIndex = $ExecuteIndex + $procedure.EndIndex
        }
    }
    return [pscustomobject]@{
        Success = $true
        Dynamic = $false
        Name = $name
        Parts = $procedure.Parts
        Statement = $statement
        Arguments = $statement.Substring($procedure.EndIndex)
        Expression = ''
        ProcedureStartIndex = $ExecuteIndex + $procedureStart
        ProcedureEndIndex = $ExecuteIndex + $procedure.EndIndex
    }
}

function Test-SqlStableStringVariable {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$VariableName,
        [string]$RequiredValue
    )

    $tokens = @(ConvertTo-SqlToken -Text (ConvertTo-CommentFreeSql -Text $Text))
    $values = @(
        for ($index = 0; $index -lt $tokens.Count; $index++) {
            Get-SqlCanonicalTokenText -Tokens $tokens -StartIndex $index -EndIndex $index
        }
    )
    $canonicalName = $VariableName.ToUpperInvariant()
    $declarationCount = 0
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        if (
            $values[$index] -eq 'DECLARE' -and
            $index + 1 -lt $tokens.Count -and
            $values[$index + 1] -eq $canonicalName
        ) {
            if (
                $index + 6 -ge $tokens.Count -or
                ($values[$index..($index + 6)] -join '|') -cne (
                    "DECLARE|$canonicalName|SYSNAME|=|N|<STRING>|;"
                )
            ) {
                return $false
            }
            $declarationCount++
            if (
                $PSBoundParameters.ContainsKey('RequiredValue') -and
                $tokens[$index + 5].LiteralValue -cne $RequiredValue
            ) {
                return $false
            }
        }
        if (
            $values[$index] -eq 'SET' -and
            $index + 1 -lt $tokens.Count -and
            $values[$index + 1] -eq $canonicalName
        ) {
            return $false
        }
        if ($values[$index] -eq $canonicalName) {
            $isAssignment = (
                $index + 1 -lt $values.Count -and
                $values[$index + 1] -eq '='
            ) -or (
                $index + 2 -lt $values.Count -and
                $values[$index + 1] -in @('+', '-', '*', '/', '%', '&', '|', '^') -and
                $values[$index + 2] -eq '='
            )
            if ($isAssignment) {
                for ($cursor = $index - 1; $cursor -ge 0; $cursor--) {
                    if ($values[$cursor] -eq ';') {
                        break
                    }
                    if ($values[$cursor] -eq 'SELECT') {
                        return $false
                    }
                }
            }
        }
        if (
            $values[$index] -eq $canonicalName -and
            $index + 1 -lt $tokens.Count -and
            $values[$index + 1] -eq 'OUTPUT'
        ) {
            return $false
        }
    }
    return $declarationCount -eq 1
}

function Test-SqlProcedureArgumentShape {
    param(
        [Parameter(Mandatory)][object]$Procedure,
        [Parameter(Mandatory)][string]$ExpectedPath
    )

    if (($Procedure.Parts -join '.').ToLowerInvariant() -cne $ExpectedPath) {
        return $false
    }
    if (-not $Procedure.Statement.TrimEnd().EndsWith(';')) {
        return $false
    }
    $arguments = ConvertTo-CommentFreeSql -Text $Procedure.Arguments
    switch ($Procedure.Name) {
        { $_ -in @('sp_add_job', 'sp_update_job') } {
            return $arguments -match (
                "^(?is)\s*@job_name\s*=\s*@JobName\s*,\s*@enabled\s*=\s*1\s*,\s*" +
                "@description\s*=\s*N'Idempotent CI/CD-managed SQL MI maintenance example\.'\s*,\s*" +
                '@owner_login_name\s*=\s*@OwnerLoginName\s*;\s*$'
            )
        }
        { $_ -in @('sp_add_jobstep', 'sp_update_jobstep') } {
            return $arguments -match (
                "^(?is)\s*@job_name\s*=\s*@JobName\s*,\s*@step_id\s*=\s*1\s*,\s*" +
                "@step_name\s*=\s*@StepName\s*,\s*@subsystem\s*=\s*N'TSQL'\s*,\s*" +
                "@database_name\s*=\s*N'master'\s*,\s*@command\s*=\s*N'SELECT 1;'\s*;\s*$"
            )
        }
        'sp_add_jobserver' {
            return $arguments -match (
                '^(?is)\s*@job_name\s*=\s*@JobName\s*,\s*' +
                '@server_name\s*=\s*@LocalServerName\s*;\s*$'
            )
        }
        default {
            return $false
        }
    }
}

function Test-SqlInstanceMutationCorrelation {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][object[]]$Tokens,
        [Parameter(Mandatory)][int]$MutationIndex,
        [Parameter(Mandatory)][object]$Guard
    )

    $token = $Tokens[$MutationIndex]
    $predicate = $Guard.Predicate
    $isMissingBranch = (
        $Guard.Branch -eq 'If' -and $Guard.IsNotExists
    ) -or (
        $Guard.Branch -eq 'Else' -and -not $Guard.IsNotExists
    )
    $isExistingBranch = -not $isMissingBranch
    if ($token.Value -eq 'CREATE') {
        if (
            $MutationIndex + 1 -ge $Tokens.Count -or
            $Tokens[$MutationIndex + 1].Kind -ne 'Word' -or
            $Tokens[$MutationIndex + 1].Value -ne 'LOGIN'
        ) {
            return $false
        }
        $login = [regex]::Match(
            $Text.Substring($token.Index),
            '^(?is)CREATE\s+LOGIN\s+\[(?<Name>[^\]]+)\]'
        )
        if (-not $login.Success -or $predicate -notmatch '\bSERVER_PRINCIPALS\b') {
            return $false
        }
        $predicateName = [regex]::Match(
            $Guard.PredicateText,
            '^(?is)\s*IF\s+(?:NOT\s+)?EXISTS\s*\(\s*SELECT\s+1\s+' +
                'FROM\s+\[?sys\]?\s*\.\s*\[?server_principals\]?\s+' +
                'WHERE\s+\[?name\]?\s*=\s*N''(?<Name>[^'']+)''\s*\)\s*$'
        )
        return (
            $isMissingBranch -and
            $predicateName.Success -and
            $predicateName.Groups['Name'].Value -ceq $login.Groups['Name'].Value
        )
    }
    if ($token.Value -notin @('EXEC', 'EXECUTE')) {
        return $false
    }

    $procedure = Get-SqlProcedureInvocationDetail -Text $Text -ExecuteIndex $token.Index
    if (-not $procedure.Success) {
        return $false
    }
    if ($procedure.Dynamic) {
        return $false
    }
    if (Test-SqlDestructiveProcedureName -Name $procedure.Name) {
        return $false
    }
    if (
        -not (
            Test-SqlProcedureArgumentShape `
                -Procedure $procedure `
                -ExpectedPath "msdb.dbo.$($procedure.Name)"
        )
    ) {
        return $false
    }

    $statementTokens = @(
        ConvertTo-SqlToken -Text (ConvertTo-CommentFreeSql -Text $procedure.Statement)
    )
    $statement = Get-SqlCanonicalTokenText `
        -Tokens $statementTokens `
        -StartIndex 0 `
        -EndIndex ($statementTokens.Count - 1)
    switch ($procedure.Name) {
        'sp_add_job' {
            return (
                $isMissingBranch -and
                $predicate -match (
                    '^IF (?:NOT )?EXISTS \( SELECT 1 FROM MSDB \. DBO \. ' +
                    'SYSJOBS WHERE NAME = @JOBNAME \)$'
                ) -and
                $statement -match '@JOB_NAME\s*=\s*@JOBNAME\b' -and
                (Test-SqlStableStringVariable -Text $Text -VariableName '@JobName')
            )
        }
        'sp_update_job' {
            return (
                $isExistingBranch -and
                $predicate -match (
                    '^IF (?:NOT )?EXISTS \( SELECT 1 FROM MSDB \. DBO \. ' +
                    'SYSJOBS WHERE NAME = @JOBNAME \)$'
                ) -and
                $statement -match '@JOB_NAME\s*=\s*@JOBNAME\b' -and
                (Test-SqlStableStringVariable -Text $Text -VariableName '@JobName')
            )
        }
        'sp_add_jobstep' {
            return (
                $isMissingBranch -and
                $predicate -match (
                    '^IF (?:NOT )?EXISTS \( SELECT 1 FROM MSDB \. DBO \. ' +
                    'SYSJOBSTEPS AS JOBSTEP INNER JOIN MSDB \. DBO \. SYSJOBS AS JOB ' +
                    'ON JOB \. JOB_ID = JOBSTEP \. JOB_ID WHERE JOB \. NAME = @JOBNAME ' +
                    'AND JOBSTEP \. STEP_ID = 1 AND JOBSTEP \. STEP_NAME = @STEPNAME \)$'
                ) -and
                $statement -match '@JOB_NAME\s*=\s*@JOBNAME\b' -and
                $statement -match '@STEP_ID\s*=\s*1\b' -and
                $statement -match '@STEP_NAME\s*=\s*@STEPNAME\b' -and
                (Test-SqlStableStringVariable -Text $Text -VariableName '@JobName') -and
                (
                    Test-SqlStableStringVariable `
                        -Text $Text `
                        -VariableName '@StepName' `
                        -RequiredValue 'Health check'
                )
            )
        }
        'sp_update_jobstep' {
            return (
                $isExistingBranch -and
                $predicate -match (
                    '^IF (?:NOT )?EXISTS \( SELECT 1 FROM MSDB \. DBO \. ' +
                    'SYSJOBSTEPS AS JOBSTEP INNER JOIN MSDB \. DBO \. SYSJOBS AS JOB ' +
                    'ON JOB \. JOB_ID = JOBSTEP \. JOB_ID WHERE JOB \. NAME = @JOBNAME ' +
                    'AND JOBSTEP \. STEP_ID = 1 AND JOBSTEP \. STEP_NAME = @STEPNAME \)$'
                ) -and
                $statement -match '@JOB_NAME\s*=\s*@JOBNAME\b' -and
                $statement -match '@STEP_NAME\s*=\s*@STEPNAME\b' -and
                $statement -match '@STEP_ID\s*=\s*1\b' -and
                (Test-SqlStableStringVariable -Text $Text -VariableName '@JobName') -and
                (
                    Test-SqlStableStringVariable `
                        -Text $Text `
                        -VariableName '@StepName' `
                        -RequiredValue 'Health check'
                )
            )
        }
        'sp_add_jobserver' {
            return (
                $isMissingBranch -and
                $predicate -match (
                    '^IF (?:NOT )?EXISTS \( SELECT 1 FROM MSDB \. DBO \. ' +
                    'SYSJOBSERVERS AS JOBSERVER INNER JOIN MSDB \. DBO \. SYSJOBS AS JOB ' +
                    'ON JOB \. JOB_ID = JOBSERVER \. JOB_ID WHERE JOB \. NAME = @JOBNAME ' +
                    'AND JOBSERVER \. SERVER_ID = 0 \)$'
                ) -and
                $statement -match '@JOB_NAME\s*=\s*@JOBNAME\b' -and
                $statement -match '@SERVER_NAME\s*=\s*@LOCALSERVERNAME\b' -and
                (Test-SqlStableStringVariable -Text $Text -VariableName '@JobName') -and
                (
                    Test-SqlStableStringVariable `
                        -Text $Text `
                        -VariableName '@LocalServerName' `
                        -RequiredValue '(LOCAL)'
                ) -and
                (Test-SqlStableStringVariable -Text $Text -VariableName '@JobName')
            )
        }
        default {
            return $false
        }
    }
}

function Test-SqlDestructiveInstanceStatement {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $tokens = @(ConvertTo-SqlToken -Text (ConvertTo-CodeOnly -Text $Text))
    if (Test-SqlUnsupportedInstanceMutation -Text $Text) {
        return $true
    }
    foreach ($token in $tokens) {
        if (
            $token.Kind -in @('Word', 'Identifier') -and
            (
                Test-SqlDestructiveProcedureName `
                    -Name (Get-SqlCanonicalTokenValue -Token $token)
            )
        ) {
            return $true
        }
    }
    return @(
        $tokens |
            Where-Object {
                $_.Kind -eq 'Word' -and
                $_.Value -in @('DROP', 'TRUNCATE')
            }
    ).Count -gt 0
}

function Test-SqlCmdValue {
    param(
        [AllowEmptyString()][string]$Value,
        [switch]$AllowEmpty
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return $AllowEmpty.IsPresent
    }
    return (
        $Value -match '^[A-Za-z0-9_.@#:/\\ =\-]+$' -and
        -not $Value.Contains('--') -and
        -not $Value.Contains('/*') -and
        -not $Value.Contains('*/')
    )
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

function Get-SqlCmdReferenceName {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $referenceSource = $Text.Replace('`$(', '__SQLCMD_ESCAPED_REFERENCE__')
    return @(
        [regex]::Matches(
            $referenceSource,
            '\$\((?<name>[A-Za-z_][A-Za-z0-9_]*)\)'
        ) |
            ForEach-Object { $_.Groups['name'].Value } |
            Sort-Object -Unique
    )
}

function Assert-NoSqlCmdControl {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $state = 'Code'
    $blockDepth = 0
    foreach ($line in $Text.Split("`n")) {
        $firstNonWhitespace = 0
        while (
            $firstNonWhitespace -lt $line.Length -and
            [char]::IsWhiteSpace($line[$firstNonWhitespace])
        ) {
            $firstNonWhitespace++
        }
        if (
            $state -notin @('String', 'BlockComment') -and
            $firstNonWhitespace -lt $line.Length -and
            (
                $line[$firstNonWhitespace] -eq ':' -or
                $line.Substring($firstNonWhitespace).StartsWith('!!')
            )
        ) {
            throw 'SQLCMD variable expansion produced a forbidden control command.'
        }
        $lexicalState = Get-SqlLexicalState `
            -Line $line `
            -State $state `
            -BlockDepth $blockDepth
        $state = $lexicalState.State
        $blockDepth = $lexicalState.BlockDepth
    }
}

function Resolve-SqlCmdScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,
        [Collections.IDictionary]$CanonicalVariables = @{},
        [Collections.IDictionary]$ExternalVariables = @{},
        [switch]$DisallowSetVariableDirectives,
        [switch]$RequireExactExternalVariables
    )

    $text = (Get-Content -Path $Path -Raw).Replace("`r`n", "`n").Replace("`r", "`n")
    $variables = [ordered]@{}
    $variableNames = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($externalName in $ExternalVariables.Keys) {
        $name = [string]$externalName
        $value = [string]$ExternalVariables[$externalName]
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Invalid external SQLCMD variable name '$name'."
        }
        if (-not $variableNames.Add($name)) {
            throw "Duplicate external SQLCMD variable declaration: $name"
        }
        if (
            [string]::IsNullOrWhiteSpace($value) -or
            -not (Test-SqlCmdValue -Value $value)
        ) {
            throw "External SQLCMD variable '$name' contains a value that cannot be reviewed safely."
        }
        $variables[$name] = $value
    }
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
                if ($DisallowSetVariableDirectives) {
                    throw 'SQLCMD setvar directives are not allowed in this script contract.'
                }
                $name = $setVariable.Groups['name'].Value
                $value = $setVariable.Groups['value'].Value
                if (-not $variableNames.Add($name)) {
                    throw "Duplicate SQLCMD variable declaration: $name"
                }
                if (
                    -not (Test-SqlCmdValue -Value $value -AllowEmpty)
                ) {
                    throw "SQLCMD variable '$name' contains a value that cannot be reviewed safely."
                }
                $variables[$name] = $value
                $sanitizedLines.Add('')
                continue
            }
            if ($line -match '^(?i)\s*:setvar\b') {
                throw 'Malformed SQLCMD setvar directive.'
            }
            if ($line -match '^(?i)\s*:on\s+error\s+exit\s*$') {
                $sanitizedLines.Add('')
                continue
            }
            throw 'SQLCMD control command is not allowed.'
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
    if ($RequireExactExternalVariables) {
        $referencedVariables = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        foreach ($referenceName in Get-SqlCmdReferenceName -Text $sanitizedSource) {
            [void]$referencedVariables.Add($referenceName)
        }
        foreach ($externalName in $ExternalVariables.Keys) {
            if (-not $referencedVariables.Contains([string]$externalName)) {
                throw "External SQLCMD variable '$externalName' is not referenced by the script."
            }
        }
    }
    $sanitizedText = Resolve-SqlCmdVariable -Text $sanitizedSource -Variables $variables
    $canonicalText = Resolve-SqlCmdVariable -Text $sanitizedSource -Variables $canonicalValues
    Assert-NoSqlCmdControl -Text $sanitizedText
    Assert-NoSqlCmdControl -Text $canonicalText
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

Export-ModuleMember -Function @(
    'ConvertFrom-ConstantSqlExpression',
    'ConvertTo-CodeOnly',
    'ConvertTo-CommentFreeSql',
    'ConvertTo-SqlToken',
    'Get-SqlBatch',
    'Get-SqlBareProcedureInvocation',
    'Get-SqlCmdReferenceName',
    'Get-SqlStatement',
    'Read-SqlIdentifierPath',
    'Resolve-SqlCmdScript',
    'Test-ConstantDynamicDdl',
    'Test-SqlCmdValue',
    'Test-SqlDestructiveInstanceStatement',
    'Test-SqlDynamicExecution',
    'Test-SqlInstanceGuardCoverage'
)
