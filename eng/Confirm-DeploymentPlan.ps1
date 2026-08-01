[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ApprovedReportPath,
    [Parameter(Mandatory)]
    [string]$CurrentReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($path in @($ApprovedReportPath, $CurrentReportPath)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Deployment report not found: $path"
    }
}

function ConvertTo-StableXml {
    param([System.Xml.XmlNode]$Node)

    if ($Node.NodeType -eq [System.Xml.XmlNodeType]::Comment) {
        return ''
    }
    if ($Node.NodeType -in @(
        [System.Xml.XmlNodeType]::Text,
        [System.Xml.XmlNodeType]::CDATA
    )) {
        if ([string]::IsNullOrWhiteSpace($Node.Value)) {
            return ''
        }
        return [System.Security.SecurityElement]::Escape($Node.Value.Trim())
    }
    if ($Node.NodeType -ne [System.Xml.XmlNodeType]::Element) {
        return ''
    }

    $attributeText = @(
        $Node.Attributes |
            Where-Object { $_.LocalName -notmatch '^(generatedAt|timestamp)$' } |
            Sort-Object NamespaceURI, LocalName |
            ForEach-Object {
                " $($_.Name)=`"$([System.Security.SecurityElement]::Escape($_.Value))`""
            }
    ) -join ''

    $children = @(
        foreach ($child in $Node.ChildNodes) {
            ConvertTo-StableXml -Node $child
        }
    ) -join ''

    return "<$($Node.Name)$attributeText>$children</$($Node.Name)>"
}

function Get-ReportHash {
    param([string]$Path)

    [xml]$document = Get-Content -Path $Path -Raw
    $stableXml = ConvertTo-StableXml -Node $document.DocumentElement
    $bytes = [Text.Encoding]::UTF8.GetBytes($stableXml)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash)
}

$approvedHash = Get-ReportHash -Path $ApprovedReportPath
$currentHash = Get-ReportHash -Path $CurrentReportPath

if ($approvedHash -ne $currentHash) {
    throw 'The target database changed after approval. Generate and approve a new deployment plan.'
}

Write-Host "Approved deployment plan still matches the target database: $approvedHash"
