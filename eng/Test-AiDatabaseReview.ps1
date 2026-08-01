[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$reviewScript = Join-Path $PSScriptRoot 'Invoke-AiDatabaseReview.ps1'
$fixtures = [IO.Path]::Combine($repoRoot, 'tests', 'fixtures')
$temporaryPath = Join-Path ([IO.Path]::GetTempPath()) "sqlmi-ai-review-tests-$PID"
New-Item -ItemType Directory -Force -Path $temporaryPath | Out-Null

function Assert-Equal {
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ("$Actual" -cne "$Expected") {
        throw "$Message Expected '$Expected', received '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    try {
        & $Action
    }
    catch {
        return
    }
    throw $Message
}

try {
    $batchPadding = @(
        1..12 | ForEach-Object {
            "+-- deterministic diff padding $_ 0123456789012345678901234567890123456789"
        }
    )
    $chunkedInput = @(
        (@("+SELECT 1 AS [BatchOne];") + $batchPadding + '+GO') -join "`n"
        (@("+SELECT 2 AS [BatchTwo];") + $batchPadding + '+GO') -join "`n"
        (@("+SELECT 3 AS [BatchThree];") + $batchPadding) -join "`n"
    ) -join "`n"
    $chunkedInputPath = Join-Path $temporaryPath 'chunked.sql'
    $chunkedOutputPath = Join-Path $temporaryPath 'chunked.json'
    Set-Content -Path $chunkedInputPath -Value $chunkedInput -Encoding utf8

    & $reviewScript `
        -ReviewInputPath $chunkedInputPath `
        -MaxInputCharacters 1000 `
        -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-multi.json') `
        -OutputPath $chunkedOutputPath

    $merged = Get-Content -Path $chunkedOutputPath -Raw | ConvertFrom-Json
    Assert-Equal $merged.risk 'high' 'Merged risk must use the defined low/medium/high maximum.'
    Assert-Equal @($merged.blockingFindings).Count 3 'Every chunk finding must be retained.'
    Assert-Equal @($merged.advisories).Count 3 'Every chunk advisory must be retained.'
    Assert-Equal $merged.blockingFindings[0].file 'chunked.sql' 'The first chunk must retain its source path.'
    Assert-Equal $merged.blockingFindings[1].file 'chunked.sql' 'The second chunk must retain its source path.'
    Assert-Equal $merged.blockingFindings[2].file 'chunked.sql' 'The third chunk must retain its source path.'
    Assert-Equal $merged.blockingFindings[0].line 2 'The first chunk line must remain unchanged.'
    Assert-Equal $merged.blockingFindings[1].line 18 'The second chunk line must be converted to its original global line.'
    Assert-Equal $merged.blockingFindings[2].line 34 'The third chunk line must be converted to its original global line.'
    Assert-Equal $merged.blockingFindings[0].reason 'First chunk finding.' 'Finding order must be stable.'
    Assert-Equal $merged.blockingFindings[2].reason 'Third chunk finding.' 'Finding order must preserve chunk order.'
    Assert-Equal @($merged.PSObject.Properties).Count 4 'The merged response must preserve the four-field result contract.'

    $diffPath = Join-Path $temporaryPath 'chunked.diff'
    $diffOutputPath = Join-Path $temporaryPath 'chunked-diff.json'
    $diffLines = [System.Collections.Generic.List[string]]::new()
    $diffLines.Add('diff --git a/database/App.Database/Tables/Chunked.sql b/database/App.Database/Tables/Chunked.sql')
    $diffLines.Add('--- a/database/App.Database/Tables/Chunked.sql')
    $diffLines.Add('+++ b/database/App.Database/Tables/Chunked.sql')
    foreach ($hunkStart in @(101, 201, 301)) {
        $diffLines.Add("@@ -0,0 +$hunkStart,14 @@")
        $batchNumber = (($hunkStart - 1) / 100)
        $diffLines.Add("+SELECT $batchNumber AS [Batch$batchNumber];")
        foreach ($paddingLine in $batchPadding) {
            $diffLines.Add($paddingLine)
        }
        $diffLines.Add('+GO')
    }
    Set-Content -Path $diffPath -Value $diffLines -Encoding utf8
    & $reviewScript `
        -ReviewInputPath $diffPath `
        -MaxInputCharacters 1000 `
        -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-diff-multi.json') `
        -OutputPath $diffOutputPath
    $diffReview = Get-Content -Path $diffOutputPath -Raw | ConvertFrom-Json
    Assert-Equal $diffReview.blockingFindings[0].file 'database/App.Database/Tables/Chunked.sql' 'Diff findings must retain the affected repository path.'
    Assert-Equal $diffReview.blockingFindings[0].line 101 'The first diff hunk must map to its new-file line.'
    Assert-Equal $diffReview.blockingFindings[1].line 203 'The second diff hunk must map local lines to new-file lines.'
    Assert-Equal $diffReview.blockingFindings[2].line 305 'The third diff hunk must map local lines to new-file lines.'

    $koreanFixture = Get-Content `
        -Path (Join-Path $fixtures 'ai-review-korean-diff.json') `
        -Raw |
        ConvertFrom-Json
    $koreanPath = $koreanFixture.blockingFindings[0].file
    $quotedPath = @(
        foreach ($byte in [Text.Encoding]::UTF8.GetBytes($koreanPath)) {
            if ($byte -ge 128) {
                '\' + [Convert]::ToString($byte, 8).PadLeft(3, '0')
            }
            else {
                [char]$byte
            }
        }
    ) -join ''
    $koreanDiffPath = Join-Path $temporaryPath 'korean-path.diff'
    Set-Content -Path $koreanDiffPath -Encoding utf8 -Value @(
        "diff --git `"a/$quotedPath`" `"b/$quotedPath`""
        "--- `"a/$quotedPath`""
        "+++ `"b/$quotedPath`""
        '@@ -0,0 +10,3 @@'
        '+first line'
        '+second line'
        '+third line'
    )
    $koreanOutputPath = Join-Path $temporaryPath 'korean-path.json'
    & $reviewScript `
        -ReviewInputPath $koreanDiffPath `
        -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-korean-diff.json') `
        -OutputPath $koreanOutputPath
    $koreanReview = Get-Content -Path $koreanOutputPath -Raw | ConvertFrom-Json
    Assert-Equal $koreanReview.blockingFindings[0].file $koreanPath 'A quoted Korean diff path must not be assigned to the previous file.'
    Assert-Equal $koreanReview.blockingFindings[0].line 11 'A quoted Korean diff path must retain its new-file line mapping.'
    $spaceDiffPath = Join-Path $temporaryPath 'space-path.diff'
    Set-Content -Path $spaceDiffPath -Encoding utf8 -Value @(
        'diff --git a/database/App.Database/Sample Data.sql b/database/App.Database/Sample Data.sql'
        '--- a/database/App.Database/Sample Data.sql'
        '+++ b/database/App.Database/Sample Data.sql'
        '@@ -0,0 +20,2 @@'
        '+SELECT 1;'
        '+DROP TABLE [app].[Danger];'
    )
    $spaceOutputPath = Join-Path $temporaryPath 'space-path.json'
    & $reviewScript `
        -ReviewInputPath $spaceDiffPath `
        -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-space-path.json') `
        -OutputPath $spaceOutputPath
    $spaceReview = Get-Content -Path $spaceOutputPath -Raw | ConvertFrom-Json
    Assert-Equal $spaceReview.blockingFindings[0].file 'database/App.Database/Sample Data.sql' 'An unquoted Git path containing spaces must be reviewed.'
    Assert-Equal $spaceReview.blockingFindings[0].line 20 'A path containing spaces must retain its new-file line mapping.'
    $mixedDiffPath = Join-Path $temporaryPath 'mixed-quoted-paths.diff'
    Set-Content -Path $mixedDiffPath -Encoding utf8 -Value @(
        "diff --git `"a/docs/old.md`" b/$koreanPath"
        '--- "a/docs/old.md"'
        "+++ b/$koreanPath"
        '@@ -1 +40,1 @@'
        '+first mixed direction'
        "diff --git a/docs/old.md `"b/$quotedPath`""
        '--- a/docs/old.md'
        "+++ `"b/$quotedPath`""
        '@@ -1 +70,1 @@'
        '+second mixed direction'
        'diff --git a/database/App.Database/Tables/Following.sql b/database/App.Database/Tables/Following.sql'
        '--- a/database/App.Database/Tables/Following.sql'
        '+++ b/database/App.Database/Tables/Following.sql'
        '@@ -1 +90,1 @@'
        '+following file'
    )
    $mixedOutputPath = Join-Path $temporaryPath 'mixed-quoted-paths.json'
    & $reviewScript `
        -ReviewInputPath $mixedDiffPath `
        -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-mixed-paths.json') `
        -OutputPath $mixedOutputPath
    $mixedReview = Get-Content -Path $mixedOutputPath -Raw | ConvertFrom-Json
    Assert-Equal $mixedReview.blockingFindings[0].file $koreanPath 'Quoted-to-unquoted rename paths must use the decoded new path.'
    Assert-Equal $mixedReview.blockingFindings[0].line 40 'Quoted-to-unquoted rename paths must retain the first hunk line.'
    Assert-Equal $mixedReview.blockingFindings[1].file $koreanPath 'Unquoted-to-quoted copy paths must use the decoded new path.'
    Assert-Equal $mixedReview.blockingFindings[1].line 70 'Unquoted-to-quoted copy paths must retain the second hunk line.'
    Assert-Equal $mixedReview.blockingFindings[2].file 'database/App.Database/Tables/Following.sql' 'A mixed quoted path must not capture the following file.'
    Assert-Equal $mixedReview.blockingFindings[2].line 90 'The following file must retain its own hunk line.'
    $pathBoundaryDiff = Join-Path $temporaryPath 'path-boundary.diff'
    Set-Content -Path $pathBoundaryDiff -Encoding utf8 -Value @(
        'diff --git a/old.sql b/new b/leaf.sql'
        '--- a/old.sql'
        '+++ b/new b/leaf.sql'
        '@@ -1 +12,1 @@'
        '+boundary'
    )
    $pathBoundaryOutput = Join-Path $temporaryPath 'path-boundary.json'
    & $reviewScript `
        -ReviewInputPath $pathBoundaryDiff `
        -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-ambiguous-space-path.json') `
        -OutputPath $pathBoundaryOutput
    $pathBoundaryReview = Get-Content $pathBoundaryOutput -Raw | ConvertFrom-Json
    Assert-Equal $pathBoundaryReview.blockingFindings[0].file 'new b/leaf.sql' 'An unquoted new path must retain separator-like text.'
    Assert-Equal $pathBoundaryReview.blockingFindings[0].line 12 'An unquoted new path must retain its hunk line.'
    $oldPathBoundaryDiff = Join-Path $temporaryPath 'old-path-boundary.diff'
    Set-Content -Path $oldPathBoundaryDiff -Encoding utf8 -Value @(
        'diff --git a/old b/part.sql b/new.sql'
        '--- a/old b/part.sql'
        '+++ b/new.sql'
        '@@ -1 +32,1 @@'
        '+old boundary'
    )
    $oldPathBoundaryOutput = Join-Path $temporaryPath 'old-path-boundary.json'
    & $reviewScript `
        -ReviewInputPath $oldPathBoundaryDiff `
        -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-ambiguous-old-path.json') `
        -OutputPath $oldPathBoundaryOutput
    $oldPathBoundaryReview = Get-Content $oldPathBoundaryOutput -Raw | ConvertFrom-Json
    Assert-Equal $oldPathBoundaryReview.blockingFindings[0].file 'new.sql' 'Separator-like text in an old path must not capture the new path.'
    Assert-Equal $oldPathBoundaryReview.blockingFindings[0].line 32 'An unquoted old path must retain the new hunk line.'

    $emojiPath = "docs/$([char]::ConvertFromUtf32(0x1F600)).md"
    $emojiDiff = Join-Path $temporaryPath 'emoji-path.diff'
    Set-Content -Path $emojiDiff -Encoding utf8 -Value @(
        "diff --git `"a/docs/old.md`" `"b/$emojiPath`""
        '--- "a/docs/old.md"'
        "+++ `"b/$emojiPath`""
        '@@ -1 +22,1 @@'
        '+emoji'
    )
    $emojiOutput = Join-Path $temporaryPath 'emoji-path.json'
    & $reviewScript `
        -ReviewInputPath $emojiDiff `
        -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-emoji-path.json') `
        -OutputPath $emojiOutput
    $emojiReview = Get-Content $emojiOutput -Raw | ConvertFrom-Json
    Assert-Equal $emojiReview.blockingFindings[0].file $emojiPath 'A quoted non-BMP path must preserve its Unicode code point.'
    Assert-Equal $emojiReview.blockingFindings[0].line 22 'A quoted non-BMP path must retain its hunk line.'
    foreach ($invalidDiff in @(
        @{
            Header = 'diff --git "a/docs/\q.md" b/docs/new.md'
            Old = '--- "a/docs/\q.md"'
            New = '+++ b/docs/new.md'
        },
        @{
            Header = 'diff --git "a/docs/old.md"b/docs/new.md'
            Old = '--- "a/docs/old.md"'
            New = '+++ b/docs/new.md'
        }
    )) {
        $invalidDiffPath = Join-Path $temporaryPath (([guid]::NewGuid().ToString('N')) + '.diff')
        Set-Content -Path $invalidDiffPath -Encoding utf8 -Value @(
            $invalidDiff.Header,
            $invalidDiff.Old,
            $invalidDiff.New,
            '@@ -1 +1 @@',
            '+invalid'
        )
        Assert-Throws {
            & $reviewScript `
                -ReviewInputPath $invalidDiffPath `
                -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-path-parser.json') `
                -OutputPath (Join-Path $temporaryPath 'invalid-path.json')
        } "Malformed Git path header must fail closed: $($invalidDiff.Header)"
    }
    $reviewScriptText = Get-Content -Path $reviewScript -Raw
    Assert-Equal `
        ([bool]($reviewScriptText -match 'git\s+-c\s+core\.quotePath=false\s+diff')) `
        $true `
        'Generated Git diffs must disable path quoting explicitly.'

    Assert-Throws {
        & $reviewScript `
            -ReviewInputPath $chunkedInputPath `
            -MaxInputCharacters 1000 `
            -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-multi.json') `
            -OutputPath (Join-Path $temporaryPath 'blocking.json') `
            -FailOnBlockingFindings
    } '-FailOnBlockingFindings should fail after merged blocking findings are evaluated.'

    $oversizeInputPath = Join-Path $temporaryPath 'oversize-single-batch.sql'
    Set-Content `
        -Path $oversizeInputPath `
        -Value ("SELECT N'" + ('x' * 1500) + "' AS [LosslessFallback];") `
        -Encoding utf8
    & $reviewScript `
        -ReviewInputPath $oversizeInputPath `
        -MaxInputCharacters 1000 `
        -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-two.json') `
        -OutputPath (Join-Path $temporaryPath 'oversize.json')
    $oversize = Get-Content -Path (Join-Path $temporaryPath 'oversize.json') -Raw | ConvertFrom-Json
    Assert-Equal $oversize.risk 'medium' 'The oversized single-batch fallback must merge every lossless window.'

    $syntaxOnlyInputPath = Join-Path $temporaryPath 'syntax-only.sql'
    Set-Content -Path $syntaxOnlyInputPath -Encoding utf8 -Value @'
DECLARE @Password nvarchar(128);
CREATE LOGIN [sample_login] WITH PASSWORD = @Password;
'@
    & $reviewScript `
        -ReviewInputPath $syntaxOnlyInputPath `
        -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-single.json') `
        -OutputPath (Join-Path $temporaryPath 'syntax-only.json')

    $credential = @('NotAReal', 'Credential', '2026', 'HighEntropy') -join '-'
    $secretInputPath = Join-Path $temporaryPath 'credential-literal.sql'
    Set-Content `
        -Path $secretInputPath `
        -Value "CREATE LOGIN [sample_login] WITH PASSWORD = N'$credential';" `
        -Encoding utf8
    Assert-Throws {
        & $reviewScript `
            -ReviewInputPath $secretInputPath `
            -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-single.json') `
            -OutputPath (Join-Path $temporaryPath 'credential-literal.json')
    } 'A long, high-entropy credential literal must be rejected.'

    $shortSecretInputPath = Join-Path $temporaryPath 'short-credential-literal.sql'
    $shortCredential = @('P@ss', 'w0rd!') -join ''
    Set-Content `
        -Path $shortSecretInputPath `
        -Value "CREATE LOGIN [sample_login] WITH PASSWORD = N'$shortCredential';" `
        -Encoding utf8
    Assert-Throws {
        & $reviewScript `
            -ReviewInputPath $shortSecretInputPath `
            -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-single.json') `
            -OutputPath (Join-Path $temporaryPath 'short-credential-literal.json')
    } 'Any concrete credential literal must be rejected.'

    Assert-Throws {
        & $reviewScript `
            -ValidateOnlyResponsePath (Join-Path $fixtures 'ai-review-malformed.json') `
            -OutputPath (Join-Path $temporaryPath 'malformed.json')
    } 'A malformed response must fail validation.'

    Write-Host 'All offline AI review chunking, merge, and secret detection tests passed.'
}
finally {
    if (Test-Path $temporaryPath) {
        Remove-Item -Path $temporaryPath -Recurse -Force
    }
}
