[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DocxPath,

    [int]$ExpectedImageCount = 0,

    [string[]]$RequiredText = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$resolvedDocx = [IO.Path]::GetFullPath($DocxPath)
if (-not (Test-Path -LiteralPath $resolvedDocx -PathType Leaf)) {
    throw "DOCX 不存在：$resolvedDocx"
}

function Read-ZipEntryText {
    param(
        [Parameter(Mandatory)]
        [IO.Compression.ZipArchive]$Archive,

        [Parameter(Mandatory)]
        [string]$EntryName
    )

    $entry = $Archive.GetEntry($EntryName)
    if (-not $entry) {
        throw "DOCX 缺少必要条目：$EntryName"
    }

    $stream = $entry.Open()
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

function Get-StreamSha256 {
    param(
        [Parameter(Mandatory)]
        [IO.Stream]$Stream
    )

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Stream))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

$archive = [IO.Compression.ZipFile]::OpenRead($resolvedDocx)
try {
    $documentXmlText = Read-ZipEntryText -Archive $archive -EntryName 'word/document.xml'
    $relationshipsText = Read-ZipEntryText -Archive $archive -EntryName 'word/_rels/document.xml.rels'
    $mediaEntries = @($archive.Entries | Where-Object {
        $_.FullName.StartsWith('word/media/', [StringComparison]::OrdinalIgnoreCase) -and
        -not $_.FullName.EndsWith('/', [StringComparison]::Ordinal)
    })

    [xml]$documentXml = $documentXmlText
    $namespaceManager = [Xml.XmlNamespaceManager]::new($documentXml.NameTable)
    $namespaceManager.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
    $visibleText = ($documentXml.SelectNodes('//w:t', $namespaceManager) | ForEach-Object { $_.InnerText }) -join ''
    $imageDrawingCount = @($documentXml.SelectNodes('//w:drawing', $namespaceManager)).Count

    foreach ($required in $RequiredText) {
        if (-not [string]::IsNullOrWhiteSpace($required) -and $visibleText.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
            throw "DOCX 正文缺少预期文本：$required"
        }
    }

    [xml]$relationshipsXml = $relationshipsText
    $imageRelationships = @($relationshipsXml.Relationships.Relationship | Where-Object {
        $_.GetAttribute('Type').EndsWith('/image', [StringComparison]::OrdinalIgnoreCase)
    })
    $externalImageRelationships = @($imageRelationships | Where-Object {
        $_.GetAttribute('TargetMode') -eq 'External' -or $_.GetAttribute('Target') -match '^https?://'
    })
    $media = @($mediaEntries | ForEach-Object {
        $stream = $_.Open()
        try {
            [pscustomobject]@{
                entry  = $_.FullName
                bytes  = $_.Length
                sha256 = Get-StreamSha256 -Stream $stream
            }
        }
        finally {
            $stream.Dispose()
        }
    })

    if ($mediaEntries.Count -lt $ExpectedImageCount) {
        throw "DOCX 内嵌媒体数量不足：期望至少 $ExpectedImageCount，实际 $($mediaEntries.Count)。"
    }
    if ($imageRelationships.Count -lt $ExpectedImageCount) {
        throw "DOCX 图片关系数量不足：期望至少 $ExpectedImageCount，实际 $($imageRelationships.Count)。"
    }
    if ($externalImageRelationships.Count -gt 0) {
        throw "DOCX 包含 $($externalImageRelationships.Count) 个外部图片关系。"
    }

    $notionTemporaryUrlPattern = '(?i)(secure\.notion-static\.com|prod-files-secure|notion\.so/image|amazonaws\.com/.+X-Amz-(Credential|Signature))'
    $xmlEntries = @($archive.Entries | Where-Object { $_.FullName.EndsWith('.xml', [StringComparison]::OrdinalIgnoreCase) -or $_.FullName.EndsWith('.rels', [StringComparison]::OrdinalIgnoreCase) })
    foreach ($entry in $xmlEntries) {
        $stream = $entry.Open()
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        try {
            $content = $reader.ReadToEnd()
            if ($content -match $notionTemporaryUrlPattern) {
                throw "DOCX 中仍包含 Notion 临时图片地址：$($entry.FullName)"
            }
        }
        finally {
            $reader.Dispose()
            $stream.Dispose()
        }
    }

    $hash = Get-Sha256 -Path $resolvedDocx
    [pscustomobject]@{
        success                    = $true
        path                       = $resolvedDocx
        sha256                     = $hash
        bytes                      = (Get-Item -LiteralPath $resolvedDocx).Length
        visibleTextCharacters      = $visibleText.Length
        paragraphCount             = @($documentXml.SelectNodes('//w:p', $namespaceManager)).Count
        imageDrawingCount          = $imageDrawingCount
        mediaCount                 = $mediaEntries.Count
        media                      = $media
        imageRelationshipCount     = $imageRelationships.Count
        externalImageRelationships = $externalImageRelationships.Count
        notionTemporaryUrls        = 0
    } | ConvertTo-Json -Depth 3
}
finally {
    $archive.Dispose()
}
