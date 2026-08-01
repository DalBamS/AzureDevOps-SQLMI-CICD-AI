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

function Get-SqlBareProcedureInvocation {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $codeOnly = ConvertTo-CodeOnly -Text $Text
    $commentFree = ConvertTo-CommentFreeSql -Text $Text
    $batchStarts = [System.Collections.Generic.List[int]]::new()
    $batchEnds = [System.Collections.Generic.List[int]]::new()
    $batchStarts.Add(0)
    foreach ($goMatch in [regex]::Matches(
        $codeOnly,
        '(?im)^[\t ]*GO(?:[\t ]+\d+)?[\t ]*(?:\r?\n|$)'
    )) {
        $batchEnds.Add($goMatch.Index)
        $batchStarts.Add($goMatch.Index + $goMatch.Length)
    }
    $batchEnds.Add($Text.Length)

    $invocations = [System.Collections.Generic.List[object]]::new()
    for ($batchIndex = 0; $batchIndex -lt $batchStarts.Count; $batchIndex++) {
        $cursor = $batchStarts[$batchIndex]
        $batchEnd = $batchEnds[$batchIndex]
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
        if ($procedureName -in @('sp_delete_job', 'sp_rename')) {
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

function Test-SqlInstanceGuardCoverage {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $codeOnly = ConvertTo-CodeOnly -Text $Text
    $tokens = @(ConvertTo-SqlToken -Text $codeOnly)
    $goBatches = @(
        [regex]::Matches(
            $codeOnly,
            '(?im)^[\t ]*GO(?:[\t ]+\d+)?[\t ]*(?:\r?\n|$)'
        )
    )
    $bareMutationIndices = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($bareInvocation in @(Get-SqlBareProcedureInvocation -Text $Text)) {
        [void]$bareMutationIndices.Add($bareInvocation.Index)
    }
    $guardRanges = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        if ($tokens[$index].Kind -ne 'Word' -or $tokens[$index].Value -ne 'IF') {
            continue
        }
        $cursor = $index + 1
        if (
            $cursor -lt $tokens.Count -and
            $tokens[$cursor].Kind -eq 'Word' -and
            $tokens[$cursor].Value -eq 'NOT'
        ) {
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
                    $rangeEnd = $elseEnd
                }
            }
            $guardRanges.Add([pscustomobject]@{
                Start = $rangeStart
                End = $rangeEnd
                Batch = @(
                    $goBatches |
                        Where-Object { $_.Index -lt $tokens[$index].Index }
                ).Count
            })
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
        $mutationBatch = @(
            $goBatches |
                Where-Object { $_.Index -lt $tokens[$index].Index }
        ).Count
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
    }
    return $true
}

function Test-SqlDestructiveInstanceStatement {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $tokens = @(ConvertTo-SqlToken -Text (ConvertTo-CodeOnly -Text $Text))
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
