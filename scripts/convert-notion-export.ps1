[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputPath,
    [string]$OutputPath,
    [string]$EntryPath,
    [string]$AuxiliaryDirectory,
    [switch]$ManifestOnly,
    [switch]$SinglePage,
    [int]$ExpectedImageCount = -1,
    [string[]]$RequiredText = @(),
    [long]$ImageOptimizationTriggerBytes = 19MB,
    [long]$ImageOptimizationMinimumPngBytes = 256KB,
    [ValidateRange(1, 100)]
    [int]$ImageOptimizationJpegQuality = 92
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8Encoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8Encoding
$OutputEncoding = $utf8Encoding
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($InputPath)) { $InputPath = Join-Path $repoRoot 'tests\fixtures\notion-export' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $repoRoot 'artifacts\stage1\notion-stage1.docx' }
$resolvedInput = [IO.Path]::GetFullPath($InputPath)
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$temporaryRoot = $null

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '') }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}

function Get-RelativePathCompat {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    if ($normalizedPath.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) { return $normalizedPath.Substring($normalizedRoot.Length) }
    return $normalizedPath
}

function Assert-PathInsideRoot {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    if (-not $normalizedPath.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "$Label 超出 Notion 导出目录：$Path" }
    return $normalizedPath
}

function Get-MimeType {
    param([Parameter(Mandatory)][string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.png'  { return 'image/png' }
        '.jpg'  { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.gif'  { return 'image/gif' }
        '.webp' { return 'image/webp' }
        '.svg'  { return 'image/svg+xml' }
        default { return 'application/octet-stream' }
    }
}

function Convert-PngToJpegCopy {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][int]$Quality
    )
    Add-Type -AssemblyName System.Drawing
    $image = $null
    $bitmap = $null
    $graphics = $null
    $encoderParameters = $null
    try {
        $image = [Drawing.Image]::FromFile($SourcePath)
        $bitmap = New-Object Drawing.Bitmap($image.Width, $image.Height, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::White)
        $graphics.DrawImage($image, 0, 0, $image.Width, $image.Height)
        $jpegCodec = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
            Where-Object { $_.MimeType -eq 'image/jpeg' } |
            Select-Object -First 1
        if (-not $jpegCodec) { throw 'Windows 图像组件没有提供 JPEG 编码器。' }
        $encoderParameters = New-Object Drawing.Imaging.EncoderParameters(1)
        $encoderParameters.Param[0] = New-Object Drawing.Imaging.EncoderParameter(
            [Drawing.Imaging.Encoder]::Quality,
            [long]$Quality
        )
        $bitmap.Save($DestinationPath, $jpegCodec, $encoderParameters)
    }
    finally {
        if ($encoderParameters) { $encoderParameters.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($image) { $image.Dispose() }
    }
}

function Convert-HtmlToPlainText {
    param([AllowEmptyString()][string]$Html)
    $text = [Text.RegularExpressions.Regex]::Replace($Html, '(?is)<br\s*/?>', ' ')
    $text = [Text.RegularExpressions.Regex]::Replace($text, '(?is)<[^>]+>', '')
    $text = [Net.WebUtility]::HtmlDecode($text)
    return ([Text.RegularExpressions.Regex]::Replace($text, '\s+', ' ')).Trim()
}

function Convert-HtmlCodeToText {
    param([AllowEmptyString()][string]$Html)
    $text = [Text.RegularExpressions.Regex]::Replace($Html, '(?is)<br\s*/?>', "`n")
    $text = [Text.RegularExpressions.Regex]::Replace($text, '(?is)<[^>]+>', '')
    $text = [Net.WebUtility]::HtmlDecode($text)
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    return $text.TrimEnd([char[]]@("`r", "`n"))
}

function Normalize-CodeSyntax {
    param([AllowEmptyString()][string]$Syntax)
    $normalized = if ($null -eq $Syntax) { '' } else { $Syntax.Trim().ToLowerInvariant() }
    switch -Regex ($normalized) {
        '^(|text|plain|plain[\s_-]?text|none)$' { return 'plaintext' }
        '^js$' { return 'javascript' }
        '^ts$' { return 'typescript' }
        '^py$' { return 'python' }
        '^ps1$' { return 'powershell' }
        default {
            $safe = [Text.RegularExpressions.Regex]::Replace($normalized, '[^a-z0-9_+#.-]+', '-')
            if ([string]::IsNullOrWhiteSpace($safe)) { return 'plaintext' }
            return $safe.Trim('-')
        }
    }
}

function Get-CodeSyntaxFromAttributes {
    param([AllowEmptyString()][string[]]$AttributeSets)
    foreach ($attributes in $AttributeSets) {
        if ([string]::IsNullOrWhiteSpace($attributes)) { continue }
        foreach ($name in @('data-language', 'data-syntax', 'language')) {
            $value = Get-HtmlAttributeValue -Attributes $attributes -Name $name
            if (-not [string]::IsNullOrWhiteSpace($value)) { return Normalize-CodeSyntax -Syntax $value }
        }
    }
    foreach ($attributes in $AttributeSets) {
        if ([string]::IsNullOrWhiteSpace($attributes)) { continue }
        $classValue = Get-HtmlAttributeValue -Attributes $attributes -Name 'class'
        if ([string]::IsNullOrWhiteSpace($classValue)) { continue }
        $explicit = [Text.RegularExpressions.Regex]::Match($classValue, '(?i)(?:^|\s)(?:language|lang)-(?<syntax>[a-z0-9_+#.-]+)(?:\s|$)')
        if ($explicit.Success) { return Normalize-CodeSyntax -Syntax $explicit.Groups['syntax'].Value }
        foreach ($token in @($classValue -split '\s+')) {
            if ($token -and $token -notin @('code', 'sourceCode', 'highlight', 'notion-code')) {
                return Normalize-CodeSyntax -Syntax $token
            }
        }
    }
    return 'plaintext'
}

function Get-HtmlCodeBlocks {
    param([Parameter(Mandatory)][object]$Document)
    $blocks = [Collections.Generic.List[object]]::new()
    foreach ($pre in [Text.RegularExpressions.Regex]::Matches($Document.content, '(?is)<pre\b(?<preAttrs>[^>]*)>(?<preBody>.*?)</pre>')) {
        $code = [Text.RegularExpressions.Regex]::Match($pre.Groups['preBody'].Value, '(?is)^\s*<code\b(?<codeAttrs>[^>]*)>(?<codeBody>.*?)</code>\s*$')
        $codeBody = if ($code.Success) { $code.Groups['codeBody'].Value } else { $pre.Groups['preBody'].Value }
        $codeAttributes = if ($code.Success) { $code.Groups['codeAttrs'].Value } else { '' }
        $blocks.Add([pscustomobject]@{
            syntax = Get-CodeSyntaxFromAttributes -AttributeSets @($codeAttributes, $pre.Groups['preAttrs'].Value)
            code = Convert-HtmlCodeToText -Html $codeBody
            document = $Document.relativePath
        })
    }
    return @($blocks)
}

function Get-DocxCodeAudit {
    param([Parameter(Mandatory)][string]$Path)

    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('word/document.xml')
        if (-not $entry) { throw 'DOCX 缺少 word/document.xml，无法核对代码块结构。' }
        $reader = [IO.StreamReader]::new($entry.Open(), [Text.Encoding]::UTF8, $true)
        try { [xml]$document = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $namespaces = [Xml.XmlNamespaceManager]::new($document.NameTable)
        $namespaces.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        $blocks = [Collections.Generic.List[string]]::new()
        foreach ($paragraph in @($document.SelectNodes('//w:p[w:pPr/w:pStyle[@w:val="SourceCode"]]', $namespaces))) {
            $builder = [Text.StringBuilder]::new()
            foreach ($node in @($paragraph.SelectNodes('.//w:t | .//w:br | .//w:tab', $namespaces))) {
                switch ($node.LocalName) {
                    't' { [void]$builder.Append($node.InnerText) }
                    'br' { [void]$builder.Append("`n") }
                    'tab' { [void]$builder.Append("`t") }
                }
            }
            $blocks.Add($builder.ToString().Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd([char[]]@("`r", "`n")))
        }
        return [pscustomobject]@{ detectedCount = $blocks.Count; codeSequence = @($blocks) }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-DocxRootTitleAudit {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootTitle
    )

    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('word/document.xml')
        if (-not $entry) { throw 'DOCX 缺少 word/document.xml，无法核对根页面标题。' }
        $reader = [IO.StreamReader]::new($entry.Open(), [Text.Encoding]::UTF8, $true)
        try { [xml]$document = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $namespaces = [Xml.XmlNamespaceManager]::new($document.NameTable)
        $namespaces.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        $titleStyleCount = 0
        $duplicateRootHeadingCount = 0
        foreach ($paragraph in @($document.SelectNodes('//w:body//w:p', $namespaces))) {
            $styleNode = $paragraph.SelectSingleNode('./w:pPr/w:pStyle', $namespaces)
            $style = if ($styleNode) { $styleNode.GetAttribute('val', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main') } else { '' }
            $text = (@($paragraph.SelectNodes('.//w:t', $namespaces)) | ForEach-Object { $_.InnerText }) -join ''
            if ($style -eq 'Title') { $titleStyleCount += 1 }
            if ($style -eq 'Heading1' -and $text.Trim() -ceq $RootTitle.Trim()) { $duplicateRootHeadingCount += 1 }
        }
        return [pscustomobject]@{
            titleStyleParagraphCount = $titleStyleCount
            duplicateRootHeadingCount = $duplicateRootHeadingCount
            duplicateTitleBlockCount = $titleStyleCount + $duplicateRootHeadingCount
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-DocxTodoAudit {
    param([Parameter(Mandatory)][string]$Path)

    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('word/document.xml')
        if (-not $entry) { throw 'DOCX 缺少 word/document.xml，无法核对待办结构。' }
        $reader = [IO.StreamReader]::new($entry.Open(), [Text.Encoding]::UTF8, $true)
        try { [xml]$document = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $namespaces = [Xml.XmlNamespaceManager]::new($document.NameTable)
        $namespaces.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        $states = [Collections.Generic.List[string]]::new()
        $ordinaryListCount = 0
        foreach ($paragraph in @($document.SelectNodes('//w:p', $namespaces))) {
            $text = (@($paragraph.SelectNodes('.//w:t', $namespaces)) | ForEach-Object { $_.InnerText }) -join ''
            $match = [Text.RegularExpressions.Regex]::Match($text, '^\s*(?<marker>[☐☒])')
            if (-not $match.Success) { continue }
            $states.Add($(if ($match.Groups['marker'].Value -eq '☒') { 'checked' } else { 'unchecked' }))
            if ($paragraph.SelectSingleNode('./w:pPr/w:numPr', $namespaces)) { $ordinaryListCount += 1 }
        }
        return [pscustomobject]@{
            detectedCount = $states.Count
            stateSequence = @($states)
            ordinaryListCount = $ordinaryListCount
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-HtmlAttributeValue {
    param([AllowEmptyString()][string]$Attributes, [Parameter(Mandatory)][string]$Name)
    $pattern = '(?is)(?:^|\s)' + [Text.RegularExpressions.Regex]::Escape($Name) + '\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')'
    $match = [Text.RegularExpressions.Regex]::Match($Attributes, $pattern)
    if (-not $match.Success) { return $null }
    $value = if ($match.Groups['double'].Success) { $match.Groups['double'].Value } else { $match.Groups['single'].Value }
    return [Net.WebUtility]::HtmlDecode($value)
}

function Test-IsExternalImageTarget {
    param([AllowEmptyString()][string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { return $false }
    return $Target -match '^(?i:https?|file|data):' -or $Target.StartsWith('//')
}

function Get-ExternalBookmarkImageCount {
    param([AllowEmptyString()][string]$Html)
    $count = 0
    $bookmarkPattern = '(?is)<a\b(?=[^>]*\bclass\s*=\s*(?:"[^"]*\bbookmark\b[^"]*"|''[^'']*\bbookmark\b[^'']*''))[^>]*>.*?</a>'
    foreach ($bookmark in [Text.RegularExpressions.Regex]::Matches($Html, $bookmarkPattern)) {
        foreach ($image in [Text.RegularExpressions.Regex]::Matches($bookmark.Value, '(?is)<img\b(?<attrs>[^>]*)>')) {
            $target = Get-HtmlAttributeValue -Attributes $image.Groups['attrs'].Value -Name 'src'
            if (Test-IsExternalImageTarget -Target $target) { $count += 1 }
        }
    }
    return $count
}

function Remove-ExternalBookmarkImages {
    param([AllowEmptyString()][string]$Html)
    $bookmarkPattern = '(?is)<a\b(?=[^>]*\bclass\s*=\s*(?:"[^"]*\bbookmark\b[^"]*"|''[^'']*\bbookmark\b[^'']*''))[^>]*>.*?</a>'
    return [Text.RegularExpressions.Regex]::Replace(
        $Html,
        $bookmarkPattern,
        [Text.RegularExpressions.MatchEvaluator]{
            param($bookmark)
            return [Text.RegularExpressions.Regex]::Replace(
                $bookmark.Value,
                '(?is)<img\b(?<attrs>[^>]*)>',
                [Text.RegularExpressions.MatchEvaluator]{
                    param($image)
                    $target = Get-HtmlAttributeValue -Attributes $image.Groups['attrs'].Value -Name 'src'
                    if (Test-IsExternalImageTarget -Target $target) { return '' }
                    return $image.Value
                }
            )
        }
    )
}

function Resolve-HtmlTarget {
    param(
        [Parameter(Mandatory)][string]$RawTarget,
        [Parameter(Mandatory)][string]$HtmlPath,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Label
    )
    $target = [Net.WebUtility]::HtmlDecode($RawTarget).Trim()
    if ([string]::IsNullOrWhiteSpace($target) -or $target.StartsWith('#')) { return $null }
    if ($target -match '^(?i:data):') { throw "$Label 不支持 data URI，无法生成可核对的本地资源哈希。" }
    if ($target -match '^(?i:https?|mailto|tel|file|javascript):' -or $target.StartsWith('//')) { return $null }
    $pathPart = ($target -split '[?#]', 2)[0]
    if ([string]::IsNullOrWhiteSpace($pathPart)) { return $null }
    try { $decodedPath = [Uri]::UnescapeDataString($pathPart) }
    catch { throw "$Label URL 解码失败：$target" }
    if ([IO.Path]::IsPathRooted($decodedPath)) { throw "$Label 不能使用绝对路径：$target" }
    $decodedPath = $decodedPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $entryDirectory = [IO.Path]::GetDirectoryName($HtmlPath)
    $candidate = [IO.Path]::GetFullPath((Join-Path $entryDirectory $decodedPath))
    return Assert-PathInsideRoot -Root $ContentRoot -Path $candidate -Label $Label
}

function Get-HtmlLinkReferences {
    param([Parameter(Mandatory)][string]$HtmlPath, [Parameter(Mandatory)][string]$ContentRoot)
    $html = [IO.File]::ReadAllText($HtmlPath)
    $references = [Collections.Generic.List[object]]::new()
    foreach ($match in [Text.RegularExpressions.Regex]::Matches($html, '(?is)<a\b(?<attrs>[^>]*)>(?<body>.*?)</a>')) {
        $target = Get-HtmlAttributeValue -Attributes $match.Groups['attrs'].Value -Name 'href'
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        $resolved = Resolve-HtmlTarget -RawTarget $target -HtmlPath $HtmlPath -ContentRoot $ContentRoot -Label '本地链接'
        if ($resolved) {
            $references.Add([pscustomobject]@{
                label = Convert-HtmlToPlainText -Html $match.Groups['body'].Value
                source = $target
                resolvedPath = $resolved
                extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
            })
        }
    }
    return @($references)
}

function Get-HtmlImageReferences {
    param([Parameter(Mandatory)][string]$HtmlPath, [Parameter(Mandatory)][string]$ContentRoot)
    $html = Remove-ExternalBookmarkImages -Html ([IO.File]::ReadAllText($HtmlPath))
    $references = [Collections.Generic.List[object]]::new()
    foreach ($match in [Text.RegularExpressions.Regex]::Matches($html, '(?is)<img\b(?<attrs>[^>]*)>')) {
        $target = Get-HtmlAttributeValue -Attributes $match.Groups['attrs'].Value -Name 'src'
        if ([string]::IsNullOrWhiteSpace($target)) { throw '检测到没有 src 的 HTML 图片。' }
        if (Test-IsExternalImageTarget -Target $target) { throw "检测到尚未本地化的外部图片地址：$target" }
        $resolved = Resolve-HtmlTarget -RawTarget $target -HtmlPath $HtmlPath -ContentRoot $ContentRoot -Label '图片路径'
        if (-not $resolved -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Notion 导出图片缺失：$target" }
        $references.Add([pscustomobject]@{
            label = Get-HtmlAttributeValue -Attributes $match.Groups['attrs'].Value -Name 'alt'
            source = $target
            resolvedPath = $resolved
        })
    }
    return @($references)
}

function Get-HtmlFiles {
    param([Parameter(Mandatory)][string]$ContentRoot)
    return @(Get-ChildItem -LiteralPath $ContentRoot -Recurse -File | Where-Object { $_.Extension -ieq '.html' -or $_.Extension -ieq '.htm' } | Sort-Object FullName)
}

function Get-HtmlEntry {
    param([Parameter(Mandatory)][string]$ContentRoot, [string]$RequestedEntry)
    if (-not [string]::IsNullOrWhiteSpace($RequestedEntry)) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $ContentRoot $RequestedEntry))
        $candidate = Assert-PathInsideRoot -Root $ContentRoot -Path $candidate -Label 'EntryPath'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "找不到指定的 HTML 入口：$RequestedEntry" }
        if ([IO.Path]::GetExtension($candidate) -notin @('.html', '.htm')) { throw 'EntryPath 必须指向 HTML 文件。' }
        return $candidate
    }
    $entries = @(Get-HtmlFiles -ContentRoot $ContentRoot)
    if ($entries.Count -eq 0) {
        $markdown = @(Get-ChildItem -LiteralPath $ContentRoot -Recurse -File -Filter '*.md')
        if ($markdown.Count -gt 0) { throw '检测到 Markdown & CSV 导出；当前只支持 HTML。请在 Notion 导出时把导出格式改为 HTML。' }
        throw '输入中没有找到 HTML 页面。请确认 Notion 导出格式选择的是 HTML。'
    }
    if ($entries.Count -eq 1) { return $entries[0].FullName }
    $referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        foreach ($link in @(Get-HtmlLinkReferences -HtmlPath $entry.FullName -ContentRoot $ContentRoot)) {
            if ($link.extension -in @('.html', '.htm')) { [void]$referenced.Add($link.resolvedPath) }
        }
    }
    $roots = @($entries | Where-Object { -not $referenced.Contains($_.FullName) })
    if ($roots.Count -eq 1) { return $roots[0].FullName }
    $relativeEntries = $entries | ForEach-Object { Get-RelativePathCompat -Root $ContentRoot -Path $_.FullName }
    throw "无法唯一推断根 HTML 页面，请使用 -EntryPath 指定入口：$($relativeEntries -join ', ')"
}

function Get-HtmlDocuments {
    param([Parameter(Mandatory)][string]$Entry, [Parameter(Mandatory)][string]$ContentRoot)
    $pending = [Collections.Generic.Queue[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $documents = [Collections.Generic.List[object]]::new()
    $pending.Enqueue([pscustomobject]@{ path = $Entry; parent = $null; source = $null })
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        if (-not $seen.Add($current.path)) { continue }
        if (-not (Test-Path -LiteralPath $current.path -PathType Leaf)) { throw "Notion 子页面缺失：$($current.source)" }
        $content = [IO.File]::ReadAllText($current.path)
        $links = @(Get-HtmlLinkReferences -HtmlPath $current.path -ContentRoot $ContentRoot)
        $relativePath = Get-RelativePathCompat -Root $ContentRoot -Path $current.path
        $documents.Add([pscustomobject]@{
            path = $current.path; relativePath = $relativePath; parent = $current.parent; source = $current.source
            content = $content; links = $links; bytes = (Get-Item -LiteralPath $current.path).Length
            characters = $content.Length; sha256 = Get-Sha256 -Path $current.path
            externalBookmarkImageCount = Get-ExternalBookmarkImageCount -Html $content
        })
        foreach ($link in $links) {
            if ($link.extension -in @('.html', '.htm')) {
                if (-not (Test-Path -LiteralPath $link.resolvedPath -PathType Leaf)) { throw "Notion 子页面缺失：$($link.source)" }
                $pending.Enqueue([pscustomobject]@{ path = $link.resolvedPath; parent = $relativePath; source = $link.source })
            }
            elseif ($link.extension -and -not (Test-Path -LiteralPath $link.resolvedPath -PathType Leaf)) { throw "Notion 导出引用的本地文件缺失：$($link.source)" }
        }
    }
    return @($documents)
}

function Expand-NotionZipLayers {
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$TemporaryRoot, [int]$MaximumDepth = 3)
    $currentZip = $ZipPath
    for ($depth = 0; $depth -lt $MaximumDepth; $depth += 1) {
        $layerRoot = Join-Path $TemporaryRoot ("export-$depth")
        [IO.Directory]::CreateDirectory($layerRoot) | Out-Null
        [IO.Compression.ZipFile]::ExtractToDirectory($currentZip, $layerRoot)
        if (@(Get-HtmlFiles -ContentRoot $layerRoot).Count -gt 0) { return $layerRoot }
        $nestedZips = @(Get-ChildItem -LiteralPath $layerRoot -Filter '*.zip' -File -Recurse)
        if ($nestedZips.Count -eq 0) {
            if (@(Get-ChildItem -LiteralPath $layerRoot -Filter '*.md' -File -Recurse).Count -gt 0) { throw '检测到 Markdown & CSV 导出；当前只支持 HTML。请在 Notion 导出时把导出格式改为 HTML。' }
            throw 'ZIP 中没有找到 HTML 页面。请确认 Notion 导出格式选择的是 HTML。'
        }
        if ($nestedZips.Count -ne 1) { throw "ZIP 中包含 $($nestedZips.Count) 个内层导出包，无法唯一识别目标页面。" }
        $currentZip = $nestedZips[0].FullName
    }
    throw "ZIP 嵌套超过 $MaximumDepth 层，已停止解压。"
}

function Get-NotionPageTitle {
    param([Parameter(Mandatory)][object]$Document)
    $pageTitle = [Text.RegularExpressions.Regex]::Match($Document.content, '(?is)<h1\b(?=[^>]*\bclass\s*=\s*["''][^"'']*\bpage-title\b[^"'']*["''])[^>]*>(?<title>.*?)</h1>')
    if ($pageTitle.Success) {
        $title = Convert-HtmlToPlainText -Html $pageTitle.Groups['title'].Value
        $title = ($title -replace '\s+[0-9a-fA-F]{32}$', '').Trim()
        if (-not [string]::IsNullOrWhiteSpace($title)) { return $title }
    }
    $headTitle = [Text.RegularExpressions.Regex]::Match($Document.content, '(?is)<title\b[^>]*>(?<title>.*?)</title>')
    if ($headTitle.Success) {
        $title = Convert-HtmlToPlainText -Html $headTitle.Groups['title'].Value
        $title = ($title -replace '\s+[0-9a-fA-F]{32}$', '').Trim()
        if (-not [string]::IsNullOrWhiteSpace($title)) { return $title }
    }
    $fallback = [IO.Path]::GetFileNameWithoutExtension($Document.path) -replace '\s+[0-9a-fA-F]{32}$', ''
    if ([string]::IsNullOrWhiteSpace($fallback)) { return '未命名页面' }
    return $fallback.Trim()
}

function Get-NotionCoverReference {
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$ContentRoot
    )
    $pattern = '(?is)<img\b(?=[^>]*\bclass\s*=\s*(?:"[^"]*\bpage-cover-image\b[^"]*"|''[^'']*\bpage-cover-image\b[^'']*''))(?<attrs>[^>]*)>'
    $match = [Text.RegularExpressions.Regex]::Match($Document.content, $pattern)
    if (-not $match.Success) { return $null }
    $source = Get-HtmlAttributeValue -Attributes $match.Groups['attrs'].Value -Name 'src'
    if ([string]::IsNullOrWhiteSpace($source)) { throw 'Notion 封面缺少 src 属性。' }
    $resolved = Resolve-HtmlTarget -RawTarget $source -HtmlPath $Document.path -ContentRoot $ContentRoot -Label '封面路径'
    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Notion 封面资源缺失：$source"
    }
    return [pscustomobject]@{ source = $source; resolvedPath = $resolved }
}

function Convert-DocumentHtml {
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][hashtable]$AssetPathMap,
        [Parameter(Mandatory)][hashtable]$AnchorMap,
        [bool]$IsRoot,
        [bool]$RemoveRootCover
    )
    $converted = Remove-ExternalBookmarkImages -Html $Document.content
    if ($IsRoot -and $RemoveRootCover) {
        $converted = [Text.RegularExpressions.Regex]::Replace(
            $converted,
            '(?is)<img\b(?=[^>]*\bclass\s*=\s*(?:"[^"]*\bpage-cover-image\b[^"]*"|''[^'']*\bpage-cover-image\b[^'']*''))[^>]*>',
            '',
            1
        )
    }
    $converted = [Text.RegularExpressions.Regex]::Replace(
        $converted,
        '(?is)(?<prefix><img\b[^>]*?\bsrc\s*=\s*)(?<quote>["''])(?<target>.*?)(?:\k<quote>)',
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $resolved = Resolve-HtmlTarget -RawTarget $match.Groups['target'].Value -HtmlPath $Document.path -ContentRoot $ContentRoot -Label '图片路径'
            if (-not $resolved -or -not $AssetPathMap.ContainsKey($resolved)) { throw "图片资源没有完成本地化：$($match.Groups['target'].Value)" }
            $quote = $match.Groups['quote'].Value
            return $match.Groups['prefix'].Value + $quote + $AssetPathMap[$resolved] + $quote
        }
    )
    $converted = [Text.RegularExpressions.Regex]::Replace(
        $converted,
        '(?is)(?<prefix><a\b[^>]*?\bhref\s*=\s*)(?<quote>["''])(?<target>.*?)(?:\k<quote>)',
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $resolved = Resolve-HtmlTarget -RawTarget $match.Groups['target'].Value -HtmlPath $Document.path -ContentRoot $ContentRoot -Label '本地链接'
            if ($resolved -and $AnchorMap.ContainsKey($resolved)) {
                $quote = $match.Groups['quote'].Value
                return $match.Groups['prefix'].Value + $quote + '#' + $AnchorMap[$resolved] + $quote
            }
            return $match.Value
        }
    )
    $bodyMatch = [Text.RegularExpressions.Regex]::Match($converted, '(?is)<body\b[^>]*>(?<body>.*)</body>')
    $body = if ($bodyMatch.Success) { $bodyMatch.Groups['body'].Value } else { $converted }
    $body = [Text.RegularExpressions.Regex]::Replace($body, '(?is)<script\b[^>]*>.*?</script>', '')
    $pageTitlePattern = '(?is)<h1\b(?=[^>]*\bclass\s*=\s*["''][^"'']*\bpage-title\b[^"'']*["''])[^>]*>(?<title>.*?)</h1>'
    $pageTitleRegex = [Text.RegularExpressions.Regex]::new($pageTitlePattern)
    if ($IsRoot) {
        if ($RemoveRootCover) {
            $body = [Text.RegularExpressions.Regex]::Replace(
                $body,
                '(?is)<img\b(?=[^>]*\bclass\s*=\s*(?:"[^"]*\bpage-cover-image\b[^"]*"|''[^'']*\bpage-cover-image\b[^'']*''))[^>]*>',
                '',
                1
            )
        }
        $withoutPageTitle = $pageTitleRegex.Replace($body, '', 1)
        if ($withoutPageTitle -ceq $body) {
            $firstHeading = [Text.RegularExpressions.Regex]::Match($body, '(?is)<h1\b[^>]*>(?<title>.*?)</h1>')
            if ($firstHeading.Success) {
                $headingTitle = Convert-HtmlToPlainText -Html $firstHeading.Groups['title'].Value
                $headingTitle = ($headingTitle -replace '\s+[0-9a-fA-F]{32}$', '').Trim()
                $rootTitle = Get-NotionPageTitle -Document $Document
                if ($headingTitle -ceq $rootTitle) {
                    $withoutPageTitle = $body.Remove($firstHeading.Index, $firstHeading.Length)
                }
            }
        }
        $body = $withoutPageTitle
        $body = [Text.RegularExpressions.Regex]::Replace($body, '(?is)<header\b[^>]*>\s*</header>', '')
        return $body.Trim()
    }
    $body = $pageTitleRegex.Replace($body, '<h2>${title}</h2>', 1)
    return ('<hr><section id="' + $AnchorMap[$Document.path] + '">' + $body.Trim() + '</section>')
}

$failure = $null
try {
    $pandoc = Get-Command pandoc -ErrorAction SilentlyContinue
    if (-not $pandoc) { throw '未找到 Pandoc。请先安装 Pandoc，并确认 pandoc 位于 PATH。' }
    $columnsFilter = Join-Path $PSScriptRoot 'notion-html-columns.lua'
    $layoutNormalizer = Join-Path $PSScriptRoot 'normalize-notion-docx-layout.ps1'
    if (-not (Test-Path -LiteralPath $columnsFilter -PathType Leaf)) { throw "缺少 HTML 多栏转换器：$columnsFilter" }
    if (-not (Test-Path -LiteralPath $layoutNormalizer -PathType Leaf)) { throw "缺少 DOCX 布局整理器：$layoutNormalizer" }

    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $temporaryRoot = Join-Path $temporaryBase ('notion2dingding-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    if (Test-Path -LiteralPath $resolvedInput -PathType Container) { $contentRoot = $resolvedInput }
    elseif (Test-Path -LiteralPath $resolvedInput -PathType Leaf) {
        if ([IO.Path]::GetExtension($resolvedInput) -ine '.zip') { throw '输入文件必须是 Notion 导出的 HTML ZIP，或者传入已解压目录。' }
        $contentRoot = Expand-NotionZipLayers -ZipPath $resolvedInput -TemporaryRoot $temporaryRoot
    }
    else { throw "输入路径不存在：$resolvedInput" }

    $htmlEntry = Get-HtmlEntry -ContentRoot $contentRoot -RequestedEntry $EntryPath
    $documents = @(Get-HtmlDocuments -Entry $htmlEntry -ContentRoot $contentRoot)
    $documentIndexByPath = @{}
    $documentTitles = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $documents.Count; $index += 1) {
        $documentIndexByPath[$documents[$index].path] = $index
        $documentTitles.Add((Get-NotionPageTitle -Document $documents[$index]))
    }

    if ($ManifestOnly) {
        $manifestLinks = [Collections.Generic.List[object]]::new()
        for ($sourceIndex = 0; $sourceIndex -lt $documents.Count; $sourceIndex += 1) {
            foreach ($link in $documents[$sourceIndex].links) {
                if ($link.extension -notin @('.html', '.htm')) { continue }
                if (-not $documentIndexByPath.ContainsKey($link.resolvedPath)) {
                    throw "Notion 子页面链接没有进入页面清单：$($link.source)"
                }
                if ([string]::IsNullOrWhiteSpace($link.label)) {
                    throw "Notion 子页面入口缺少可显示文字：$($link.source)"
                }
                $targetIndex = [int]$documentIndexByPath[$link.resolvedPath]
                $manifestLinks.Add([pscustomobject]@{
                    sourcePageIndex = $sourceIndex
                    sourcePageSha256 = $documents[$sourceIndex].sha256
                    label = $link.label
                    targetPageIndex = $targetIndex
                    targetPageSha256 = $documents[$targetIndex].sha256
                    targetTitle = $documentTitles[$targetIndex]
                })
            }
        }
        $manifestPages = @(for ($index = 0; $index -lt $documents.Count; $index += 1) {
            $document = $documents[$index]
            [pscustomobject]@{
                pageIndex = $index
                title = $documentTitles[$index]
                relativePath = $document.relativePath
                parent = $document.parent
                sha256 = $document.sha256
            }
        })
        [pscustomobject]@{
            success = $true
            inputFormat = 'html'
            mode = 'manifest'
            entry = Get-RelativePathCompat -Root $contentRoot -Path $htmlEntry
            title = $documentTitles[0]
            exportedAt = (Get-Item -LiteralPath $htmlEntry).LastWriteTimeUtc.ToString('o')
            pageCount = $documents.Count
            pages = $manifestPages
            links = @($manifestLinks)
        } | ConvertTo-Json -Depth 8
        return
    }

    if ($SinglePage) {
        $documents = @($documents[0])
        $documentIndexByPath = @{}
        $documentIndexByPath[$documents[0].path] = 0
        $documentTitles = [Collections.Generic.List[string]]::new()
        $documentTitles.Add((Get-NotionPageTitle -Document $documents[0]))
    }
    $coverReference = Get-NotionCoverReference -Document $documents[0] -ContentRoot $contentRoot
    $nativeCoverEnabled = $null -ne $coverReference -and -not [string]::IsNullOrWhiteSpace($AuxiliaryDirectory)
    $coverReferenceSkipped = $false
    $coverMapping = [pscustomobject]@{
        detectedCount = if ($coverReference) { 1 } else { 0 }
        status = if (-not $coverReference) { 'not_present' } elseif ($nativeCoverEnabled) { 'pending_native_restore' } else { 'preserved_as_body_image' }
        output = if (-not $coverReference) { '无封面' } elseif ($nativeCoverEnabled) { '钉钉原生文档封面' } else { 'DOCX 正文图片（未提供原生封面暂存目录）' }
        fileName = ''
        sha256 = ''
        bytes = 0
        mime = ''
    }
    $subpageLinks = [Collections.Generic.List[object]]::new()
    $assetByPath = @{}
    $imageReferences = [Collections.Generic.List[object]]::new()
    $databaseByPath = @{}
    $attachmentCount = 0
    $calloutCount = 0
    $toggleCount = 0
    $columnListCount = 0
    $columnCount = 0
    $htmlTableCount = 0
    $bookmarkCount = 0
    $externalBookmarkImageCount = 0
    $todoStates = [Collections.Generic.List[bool]]::new()
    $codeBlocks = [Collections.Generic.List[object]]::new()
    for ($documentIndex = 0; $documentIndex -lt $documents.Count; $documentIndex += 1) {
        $document = $documents[$documentIndex]
        $calloutCount += [Text.RegularExpressions.Regex]::Matches($document.content, '(?is)(<aside\b|class\s*=\s*["''][^"'']*\bcallout\b)').Count
        $toggleCount += [Text.RegularExpressions.Regex]::Matches($document.content, '(?is)(<details\b|class\s*=\s*["''][^"'']*\btoggle\b)').Count
        $columnListCount += [Text.RegularExpressions.Regex]::Matches($document.content, '(?is)class\s*=\s*["''][^"'']*\bcolumn-list\b').Count
        $columnCount += [Text.RegularExpressions.Regex]::Matches($document.content, '(?is)class\s*=\s*["''][^"'']*(?<![\w-])column(?![\w-])[^"'']*["'']').Count
        $htmlTableCount += [Text.RegularExpressions.Regex]::Matches($document.content, '(?is)<table\b').Count
        $bookmarkCount += [Text.RegularExpressions.Regex]::Matches($document.content, '(?is)<a\b(?=[^>]*\bclass\s*=\s*(?:"[^"]*\bbookmark\b[^"]*"|''[^'']*\bbookmark\b[^'']*''))').Count
        $externalBookmarkImageCount += $document.externalBookmarkImageCount
        foreach ($todoInput in [Text.RegularExpressions.Regex]::Matches(
            $document.content,
            '(?is)<input\b(?=[^>]*\btype\s*=\s*["'']checkbox["''])(?=[^>]*\bclass\s*=\s*["''][^"'']*\bcheckbox-(?<state>on|off)\b[^"'']*["''])[^>]*>'
        )) {
            $isChecked = $todoInput.Groups['state'].Value -ieq 'on'
            $hasCheckedAttribute = [Text.RegularExpressions.Regex]::IsMatch($todoInput.Value, '(?is)(?:^|\s)checked(?:\s*=|\s|/?>)')
            if ($isChecked -ne $hasCheckedAttribute) { throw 'Notion 待办的 checkbox-on/off 与 checked 状态不一致，已停止转换。' }
            $todoStates.Add($isChecked)
        }
        foreach ($codeBlock in @(Get-HtmlCodeBlocks -Document $document)) {
            $codeBlocks.Add($codeBlock)
        }
        foreach ($link in $document.links) {
            if ($link.extension -in @('.html', '.htm')) {
                if (-not $documentIndexByPath.ContainsKey($link.resolvedPath)) {
                    if ($SinglePage) { continue }
                    throw "Notion 子页面链接没有进入文档集合：$($link.source)"
                }
                $targetIndex = [int]$documentIndexByPath[$link.resolvedPath]
                if ($targetIndex -gt 0) {
                    if ([string]::IsNullOrWhiteSpace($link.label)) {
                        throw "Notion 子页面入口缺少可显示文字：$($link.source)"
                    }
                    $subpageLinks.Add([pscustomobject]@{
                        sourcePageIndex = $documentIndex
                        sourceTitle = $documentTitles[$documentIndex]
                        label = $link.label
                        targetPageIndex = $targetIndex
                        targetTitle = $documentTitles[$targetIndex]
                    })
                }
            }
            elseif ($link.extension -eq '.csv') {
                if (-not (Test-Path -LiteralPath $link.resolvedPath -PathType Leaf)) { throw "Notion 数据库 CSV 缺失：$($link.source)" }
                if (-not $databaseByPath.ContainsKey($link.resolvedPath)) {
                    $databaseByPath[$link.resolvedPath] = [pscustomobject]@{
                        relativePath = Get-RelativePathCompat -Root $contentRoot -Path $link.resolvedPath
                        bytes = (Get-Item -LiteralPath $link.resolvedPath).Length
                        sha256 = Get-Sha256 -Path $link.resolvedPath
                    }
                }
            }
            elseif ($link.extension -and $link.extension -notin @('.html', '.htm')) { $attachmentCount += 1 }
        }
        foreach ($reference in @(Get-HtmlImageReferences -HtmlPath $document.path -ContentRoot $contentRoot)) {
            if (
                $nativeCoverEnabled -and -not $coverReferenceSkipped -and $documentIndex -eq 0 -and
                $reference.resolvedPath -eq $coverReference.resolvedPath -and
                $reference.source -eq $coverReference.source
            ) {
                $coverReferenceSkipped = $true
                continue
            }
            $imageReferences.Add([pscustomobject]@{ document = $document.relativePath; source = $reference.source; resolvedPath = $reference.resolvedPath })
            if (-not $assetByPath.ContainsKey($reference.resolvedPath)) {
                $item = Get-Item -LiteralPath $reference.resolvedPath
                $assetByPath[$reference.resolvedPath] = [pscustomobject]@{
                    path = $reference.resolvedPath; relativePath = Get-RelativePathCompat -Root $contentRoot -Path $reference.resolvedPath
                    mime = Get-MimeType -Path $reference.resolvedPath; bytes = $item.Length; sha256 = Get-Sha256 -Path $reference.resolvedPath
                    referenceCount = 0; documents = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    sources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                }
            }
            $asset = $assetByPath[$reference.resolvedPath]
            $asset.referenceCount += 1
            [void]$asset.documents.Add($document.relativePath)
            [void]$asset.sources.Add($reference.source)
        }
    }

    $preparedAssetRoot = Join-Path $temporaryRoot 'assets'
    [IO.Directory]::CreateDirectory($preparedAssetRoot) | Out-Null
    if ($nativeCoverEnabled) {
        if (-not $coverReferenceSkipped) { throw '已识别 Notion 封面，但没有在根页面图片序列中找到对应引用。' }
        $resolvedAuxiliaryDirectory = [IO.Path]::GetFullPath($AuxiliaryDirectory)
        [IO.Directory]::CreateDirectory($resolvedAuxiliaryDirectory) | Out-Null
        $coverExtension = [IO.Path]::GetExtension($coverReference.resolvedPath).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($coverExtension)) { $coverExtension = '.bin' }
        $coverSha256 = Get-Sha256 -Path $coverReference.resolvedPath
        $coverFileName = 'notion-cover-' + $coverSha256.Substring(0, 12).ToLowerInvariant() + $coverExtension
        $coverDestination = Join-Path $resolvedAuxiliaryDirectory $coverFileName
        if (Test-Path -LiteralPath $coverDestination) { throw "拒绝覆盖已有封面暂存文件：$coverDestination" }
        Copy-Item -LiteralPath $coverReference.resolvedPath -Destination $coverDestination
        $coverMapping = [pscustomobject]@{
            detectedCount = 1
            status = 'pending_native_restore'
            output = '钉钉原生文档封面'
            fileName = $coverFileName
            sha256 = Get-Sha256 -Path $coverDestination
            bytes = (Get-Item -LiteralPath $coverDestination).Length
            mime = Get-MimeType -Path $coverDestination
        }
    }
    $hashTargetMap = @{}
    $assetPathMap = @{}
    $sourceAssetMeasurement = $assetByPath.Values | Measure-Object -Property bytes -Sum
    $sourceAssetBytes = if ($sourceAssetMeasurement) { $sourceAssetMeasurement.Sum } else { 0 }
    $shouldOptimizeImages = $sourceAssetBytes -gt $ImageOptimizationTriggerBytes
    foreach ($asset in $assetByPath.Values) {
        if (-not $hashTargetMap.ContainsKey($asset.sha256)) {
            $extension = [IO.Path]::GetExtension($asset.path).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.bin' }
            $relativeTarget = 'assets/' + $asset.sha256.ToLowerInvariant() + $extension
            $destination = Join-Path $temporaryRoot ($relativeTarget.Replace('/', '\'))
            $localizedMime = $asset.mime
            $optimized = $false
            if (
                $shouldOptimizeImages -and
                $asset.mime -eq 'image/png' -and
                $asset.bytes -gt $ImageOptimizationMinimumPngBytes
            ) {
                $optimizedRelativeTarget = 'assets/' + $asset.sha256.ToLowerInvariant() + '.jpg'
                $optimizedDestination = Join-Path $temporaryRoot ($optimizedRelativeTarget.Replace('/', '\'))
                Convert-PngToJpegCopy -SourcePath $asset.path -DestinationPath $optimizedDestination -Quality $ImageOptimizationJpegQuality
                if ((Get-Item -LiteralPath $optimizedDestination).Length -lt $asset.bytes) {
                    $relativeTarget = $optimizedRelativeTarget
                    $destination = $optimizedDestination
                    $localizedMime = 'image/jpeg'
                    $optimized = $true
                }
                else {
                    Remove-Item -LiteralPath $optimizedDestination -Force
                }
            }
            if (-not $optimized) { Copy-Item -LiteralPath $asset.path -Destination $destination -Force }
            $hashTargetMap[$asset.sha256] = [pscustomobject]@{
                relativePath = $relativeTarget
                mime = $localizedMime
                bytes = (Get-Item -LiteralPath $destination).Length
                sha256 = Get-Sha256 -Path $destination
                optimized = $optimized
            }
        }
        $assetPathMap[$asset.path] = $hashTargetMap[$asset.sha256].relativePath
    }

    $anchorMap = @{}
    for ($index = 0; $index -lt $documents.Count; $index += 1) { $anchorMap[$documents[$index].path] = 'n2dd-page-' + ($index + 1) }
    $preparedParts = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $documents.Count; $index += 1) {
        $preparedParts.Add((Convert-DocumentHtml -Document $documents[$index] -ContentRoot $contentRoot -AssetPathMap $assetPathMap -AnchorMap $anchorMap -IsRoot ($index -eq 0) -RemoveRootCover ($nativeCoverEnabled -and $index -eq 0)))
    }
    $rootTitle = Get-NotionPageTitle -Document $documents[0]
    $combinedHtml = '<!doctype html><html><head><meta charset="utf-8"></head><body>' + ($preparedParts -join [Environment]::NewLine) + '</body></html>'
    $preparedHtml = Join-Path $temporaryRoot 'combined.html'
    [IO.File]::WriteAllText($preparedHtml, $combinedHtml, $utf8Encoding)

    $assets = @($assetByPath.Values | Sort-Object relativePath | ForEach-Object {
        $localized = $hashTargetMap[$_.sha256]
        [pscustomobject]@{
            relativePath = $_.relativePath; localizedPath = $assetPathMap[$_.path]; mime = $_.mime; bytes = $_.bytes
            sha256 = $_.sha256; localizedMime = $localized.mime; localizedBytes = $localized.bytes
            localizedSha256 = $localized.sha256; optimized = $localized.optimized
            referenceCount = $_.referenceCount; documents = @($_.documents); sources = @($_.sources)
        }
    })
    $uniqueContentCount = @($hashTargetMap.Keys).Count
    $optimizedAssetCount = @($hashTargetMap.Values | Where-Object { $_.optimized }).Count
    $localizedAssetMeasurement = $hashTargetMap.Values | Measure-Object -Property bytes -Sum
    $localizedAssetBytes = if ($localizedAssetMeasurement) { $localizedAssetMeasurement.Sum } else { 0 }
    $minimumImageCount = if ($ExpectedImageCount -ge 0) { $ExpectedImageCount } else { $uniqueContentCount }

    $warnings = [Collections.Generic.List[object]]::new()
    if ($documents.Count -gt 1) { $warnings.Add([pscustomobject]@{ code = 'SUBPAGES_APPENDED'; severity = 'info'; message = "已按 HTML 链接顺序追加 $($documents.Count - 1) 个子页面。" }) }
    if ($calloutCount -gt 0) { $warnings.Add([pscustomobject]@{ code = 'CALLOUT_CONTENT_PRESERVED'; severity = 'info'; message = "已保留 $calloutCount 个 Callout 的文本内容；Notion 交互和部分背景样式不保证保留。" }) }
    if ($toggleCount -gt 0) { $warnings.Add([pscustomobject]@{ code = 'TOGGLE_EXPANDED'; severity = 'warning'; message = "已保留 $toggleCount 个 Toggle 的展开内容，折叠交互不会保留。" }) }
    if ($databaseByPath.Count -gt 0) { $warnings.Add([pscustomobject]@{ code = 'DATABASE_TO_CSV_NOTE'; severity = 'warning'; message = "检测到 $($databaseByPath.Count) 个数据库 CSV 链接；CSV 数据不会自动嵌入正文。" }) }
    if ($todoStates.Count -gt 0) { $warnings.Add([pscustomobject]@{ code = 'TODO_NATIVE_RESTORE_REQUIRED'; severity = 'info'; message = "已保留 $($todoStates.Count) 个待办的方框和勾选状态；钉钉导入后将恢复为原生可点击待办。" }) }
    if ($codeBlocks.Count -gt 0) { $warnings.Add([pscustomobject]@{ code = 'CODE_NATIVE_RESTORE_REQUIRED'; severity = 'info'; message = "已保留 $($codeBlocks.Count) 个代码块的文本与语言；钉钉导入后将恢复为原生代码块。" }) }
    if ($externalBookmarkImageCount -gt 0) {
        $warnings.Add([pscustomobject]@{
            code = 'BOOKMARK_EXTERNAL_PREVIEW_OMITTED'
            severity = 'info'
            message = "已保留 $bookmarkCount 个书签的链接和文字，并省略 $externalBookmarkImageCount 个未随导出包提供的外部站点图标或缩略图。"
        })
    }
    if ($nativeCoverEnabled) {
        $warnings.Add([pscustomobject]@{
            code = 'COVER_NATIVE_RESTORE_REQUIRED'
            severity = 'info'
            message = '已把根页面封面从 DOCX 正文移除；钉钉导入后必须恢复为原生文档封面并回读验证。'
        })
    }
    if ($optimizedAssetCount -gt 0) {
        $warnings.Add([pscustomobject]@{
            code = 'IMAGES_OPTIMIZED_FOR_DINGTALK_LIMIT'
            severity = 'info'
            message = "为避免超过钉钉 DOCX 导入上限，已在临时目录中优化 $optimizedAssetCount 张大体积 PNG；源文件保持不变。"
        })
    }

    $outputDirectory = [IO.Path]::GetDirectoryName($resolvedOutput)
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    Write-Host "[1/4] HTML 输入预检完成：$htmlEntry；文档 $($documents.Count)，图片引用 $($imageReferences.Count)，列容器 $columnListCount"
    Write-Host "[2/4] 使用 Pandoc 生成 DOCX：$resolvedOutput"
    & $pandoc.Source @($preparedHtml, '--from=html', '--to=docx', '--standalone', "--resource-path=$temporaryRoot", "--lua-filter=$columnsFilter", "--output=$resolvedOutput")
    if ($LASTEXITCODE -ne 0) { throw "Pandoc 转换失败，退出码：$LASTEXITCODE" }

    Write-Host '[3/4] 整理 DOCX 多栏宽度、图片尺寸和无边框布局'
    $layoutJson = & $layoutNormalizer -DocxPath $resolvedOutput
    $layout = $layoutJson | ConvertFrom-Json
    if (-not $layout.success) { throw 'DOCX 布局整理器没有报告成功。' }
    $singleColumnListCount = $columnListCount - $layout.layoutTableCount
    $accountedColumnCount = $layout.layoutColumnCount + $singleColumnListCount
    if (
        $singleColumnListCount -lt 0 -or
        $accountedColumnCount -ne $columnCount
    ) {
        throw "DOCX 列结构数量不一致：HTML 列容器=$columnListCount、列=$columnCount；DOCX 多列布局表=$($layout.layoutTableCount)、布局列=$($layout.layoutColumnCount)、直接输出单列=$singleColumnListCount。"
    }
    if ($layout.layoutTableCount -gt 0) {
        $warnings.Add([pscustomobject]@{
            code = 'COLUMNS_PRESERVED'
            severity = 'info'
            message = "已把 $($layout.layoutTableCount) 个真正的多栏行映射为无边框布局表，保留同一行列数和相对列宽。"
        })
    }
    if ($singleColumnListCount -gt 0) {
        $warnings.Add([pscustomobject]@{
            code = 'SINGLE_COLUMN_UNWRAPPED'
            severity = 'info'
            message = "已把 $singleColumnListCount 个单列容器直接输出，避免生成 1×1 布局表。"
        })
    }

    $todoAudit = Get-DocxTodoAudit -Path $resolvedOutput
    $expectedTodoStates = @($todoStates | ForEach-Object { if ($_) { 'checked' } else { 'unchecked' } })
    if ($todoAudit.detectedCount -ne $expectedTodoStates.Count) {
        throw "DOCX 待办数量不一致：HTML=$($expectedTodoStates.Count)，DOCX=$($todoAudit.detectedCount)。"
    }
    if (($todoAudit.stateSequence -join ',') -ne ($expectedTodoStates -join ',')) {
        throw 'DOCX 待办的已完成/未完成状态顺序与 Notion HTML 不一致。'
    }
    if ($todoAudit.ordinaryListCount -ne 0) {
        throw "仍有 $($todoAudit.ordinaryListCount) 个待办被错误编码为普通圆点列表。"
    }

    $codeAudit = Get-DocxCodeAudit -Path $resolvedOutput
    if ($codeAudit.detectedCount -ne $codeBlocks.Count) {
        throw "DOCX 代码块数量不一致：HTML=$($codeBlocks.Count)，DOCX=$($codeAudit.detectedCount)。"
    }
    for ($index = 0; $index -lt $codeBlocks.Count; $index += 1) {
        if ($codeAudit.codeSequence[$index] -cne $codeBlocks[$index].code) {
            throw "DOCX 第 $($index + 1) 个代码块文本与 Notion HTML 不一致。"
        }
    }

    $rootTitleAudit = Get-DocxRootTitleAudit -Path $resolvedOutput -RootTitle $rootTitle
    if ($rootTitleAudit.duplicateTitleBlockCount -ne 0) {
        throw "DOCX 正文仍包含 $($rootTitleAudit.duplicateTitleBlockCount) 个重复根页面标题块。"
    }

    $verifyScript = Join-Path $PSScriptRoot 'test-docx-assets.ps1'
    Write-Host '[4/4] 验证 DOCX 正文与内嵌图片'
    $verificationJson = & $verifyScript -DocxPath $resolvedOutput -ExpectedImageCount $minimumImageCount -RequiredText $RequiredText
    $verification = $verificationJson | ConvertFrom-Json
    $documentOutput = @(for ($index = 0; $index -lt $documents.Count; $index += 1) {
        $document = $documents[$index]
        [pscustomobject]@{
            pageIndex = $index; title = $documentTitles[$index]; relativePath = $document.relativePath
            parent = $document.parent; source = $document.source; bytes = $document.bytes
            characters = $document.characters; sha256 = $document.sha256
        }
    })
    $subpageTargets = @(for ($index = 1; $index -lt $documents.Count; $index += 1) {
        [pscustomobject]@{ pageIndex = $index; title = $documentTitles[$index] }
    })
    $databaseStatus = if ($databaseByPath.Count -gt 0) { 'degraded' } elseif ($htmlTableCount -gt 0) { 'preserved' } else { 'not_present' }

    Write-Host "转换成功：$resolvedOutput"
    [pscustomobject]@{
        success = $true; input = $resolvedInput; inputFormat = 'html'; entry = Get-RelativePathCompat -Root $contentRoot -Path $htmlEntry
        title = $rootTitle; output = $resolvedOutput; documentCount = $documents.Count; subpageCount = [Math]::Max(0, $documents.Count - 1)
        documents = $documentOutput; sourceCharacters = ($documents | Measure-Object -Property characters -Sum).Sum
        preparedCharacters = $combinedHtml.Length; assetCount = $uniqueContentCount; assets = $assets
        imageAudit = [pscustomobject]@{
            sourceReferenceCount = $imageReferences.Count; localizedFileCount = $assetByPath.Count; localizedAssetCount = $uniqueContentCount
            hashesComplete = @($assets | Where-Object { [string]::IsNullOrWhiteSpace($_.sha256) }).Count -eq 0
            allReferencesResolved = $true; outputMediaCount = $verification.mediaCount
            outputImageOccurrenceCount = $verification.imageDrawingCount; outputRelationshipCount = $verification.imageRelationshipCount
            optimizedAssetCount = $optimizedAssetCount; sourceAssetBytes = $sourceAssetBytes; localizedAssetBytes = $localizedAssetBytes
            optimizationJpegQuality = if ($optimizedAssetCount -gt 0) { $ImageOptimizationJpegQuality } else { $null }
        }
        mappings = [pscustomobject]@{
            documentTitle = [pscustomobject]@{
                titleStyleParagraphCount = $rootTitleAudit.titleStyleParagraphCount
                duplicateRootHeadingCount = $rootTitleAudit.duplicateRootHeadingCount
                duplicateTitleBlockCount = $rootTitleAudit.duplicateTitleBlockCount
                status = 'preserved'
                output = '仅作为钉钉文档标题，不重复写入正文'
            }
            cover = $coverMapping
            subpageLinks = [pscustomobject]@{
                detectedPageCount = $subpageTargets.Count
                detectedLinkCount = $subpageLinks.Count
                targets = $subpageTargets
                links = @($subpageLinks)
                status = if ($subpageLinks.Count -gt 0) { 'pending_native_toc' } else { 'not_present' }
                output = 'DOCX 中保留子页面入口；导入后合并为只含子页面 H2 标题的钉钉原生目录'
            }
            callout = [pscustomobject]@{ detectedCount = $calloutCount; status = if ($calloutCount -gt 0) { 'mapped' } else { 'not_present' }; output = '保留文本内容' }
            toggle = [pscustomobject]@{ detectedCount = $toggleCount; status = if ($toggleCount -gt 0) { 'degraded' } else { 'not_present' }; output = '展开后的普通内容' }
            todo = [pscustomobject]@{
                detectedCount = $todoStates.Count
                checkedCount = @($todoStates | Where-Object { $_ }).Count
                uncheckedCount = @($todoStates | Where-Object { -not $_ }).Count
                stateSequence = $expectedTodoStates
                ordinaryListCount = $todoAudit.ordinaryListCount
                status = if ($todoStates.Count -gt 0) { 'pending_native_restore' } else { 'not_present' }
                output = 'DOCX 中为无圆点的 ☐/☒ 段落，导入后恢复为钉钉原生待办'
            }
            code = [pscustomobject]@{
                detectedCount = $codeBlocks.Count
                blocks = @($codeBlocks | ForEach-Object { [pscustomobject]@{ syntax = $_.syntax; code = $_.code } })
                docxSourceCodeCount = $codeAudit.detectedCount
                status = if ($codeBlocks.Count -gt 0) { 'pending_native_restore' } else { 'not_present' }
                output = 'DOCX 中为 SourceCode 段落，导入后恢复为钉钉原生代码块'
            }
            columns = [pscustomobject]@{
                detectedListCount = $columnListCount
                detectedColumnCount = $columnCount
                singleColumnListCount = $singleColumnListCount
                multiColumnListCount = $layout.layoutTableCount
                outputLayoutTableCount = $layout.layoutTableCount
                outputLayoutColumnCount = $layout.layoutColumnCount
                tableSequence = @($layout.tableSequence)
                status = if ($columnListCount -gt 0) { 'preserved' } else { 'not_present' }
                output = '单列直接输出；两列及以上先用无边框布局表保留同行关系，导入后恢复为钉钉原生分栏'
            }
            database = [pscustomobject]@{
                detectedCount = $databaseByPath.Count + $htmlTableCount; inlineTableCount = $htmlTableCount; status = $databaseStatus
                output = if ($htmlTableCount -gt 0) { 'HTML 数据表格' } else { 'CSV 链接说明' }; files = @($databaseByPath.Values | Sort-Object relativePath)
            }
            bookmark = [pscustomobject]@{
                detectedCount = $bookmarkCount
                omittedExternalPreviewImageCount = $externalBookmarkImageCount
                status = if ($bookmarkCount -eq 0) { 'not_present' } elseif ($externalBookmarkImageCount -gt 0) { 'degraded' } else { 'preserved' }
                output = '保留书签链接和文字；未随导出包提供的外部站点图标或缩略图不进入钉钉文档'
            }
            attachments = [pscustomobject]@{ detectedReferenceCount = $attachmentCount; output = '保留本地链接，附件内容不嵌入' }
        }
        layout = $layout; warnings = @($warnings); docx = $verification
    } | ConvertTo-Json -Depth 10
}
catch {
    $failure = [pscustomobject]@{ success = $false; error = [pscustomobject]@{ code = 'CONVERSION_FAILED'; message = $_.Exception.Message; type = $_.Exception.GetType().FullName } }
}
finally {
    if ($temporaryRoot) {
        $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
        $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $temporaryName = [IO.Path]::GetFileName($resolvedTemporaryRoot)
        if ($resolvedTemporaryRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and $temporaryName.StartsWith('notion2dingding-', [StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
if ($failure) { $failure | ConvertTo-Json -Depth 4 -Compress; exit 1 }
