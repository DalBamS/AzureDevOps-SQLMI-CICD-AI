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
