[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputPath,
    [string]$OutputPath,
    [string]$EntryPath,
    [int]$ExpectedImageCount = -1,
    [string[]]$RequiredText = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8Encoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8Encoding
$OutputEncoding = $utf8Encoding
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($InputPath)) {
    $InputPath = Join-Path $repoRoot 'tests\fixtures\notion-export'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot 'artifacts\stage1\notion-stage1.docx'
}
$resolvedInput = [IO.Path]::GetFullPath($InputPath)
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$temporaryRoot = $null

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
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

function Get-RelativePathCompat {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    if ($normalizedPath.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $normalizedPath.Substring($normalizedRoot.Length)
    }
    return $normalizedPath
}

function Assert-PathInsideRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $normalizedPath = [IO.Path]::GetFullPath($Path)
    if (-not $normalizedPath.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label 超出 Notion 导出目录：$Path"
    }
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

function Get-MarkdownTarget {
    param(
        [Parameter(Mandatory)][string]$RawTarget,
        [Parameter(Mandatory)][string]$MarkdownPath,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Label
    )
    $target = $RawTarget.Trim()
    if ($target.StartsWith('<') -and $target.EndsWith('>')) {
        $target = $target.Substring(1, $target.Length - 2)
    }
    if ($target.StartsWith('#') -or $target -match '^(?i:https?|mailto|tel):') {
        return $null
    }
    if ($target -match '^(?i:data):') {
        throw "$Label 不支持 data URI，无法生成可核对的本地资源哈希。"
    }
    $pathPart = ($target -split '[?#]', 2)[0]
    if ([string]::IsNullOrWhiteSpace($pathPart)) {
        return $null
    }
    try {
        $decodedPath = [Uri]::UnescapeDataString($pathPart)
    }
    catch {
        throw "$Label URL 解码失败：$target"
    }
    if ([IO.Path]::IsPathRooted($decodedPath)) {
        throw "$Label 不能使用绝对路径：$target"
    }
    $decodedPath = $decodedPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $entryDirectory = [IO.Path]::GetDirectoryName($MarkdownPath)
    $candidate = [IO.Path]::GetFullPath((Join-Path $entryDirectory $decodedPath))
    return Assert-PathInsideRoot -Root $ContentRoot -Path $candidate -Label $Label
}

function Get-MarkdownLinks {
    param([Parameter(Mandatory)][string]$MarkdownPath, [Parameter(Mandatory)][string]$ContentRoot)
    $markdown = [IO.File]::ReadAllText($MarkdownPath)
    $matches = [Text.RegularExpressions.Regex]::Matches(
        $markdown,
        '(?<!!)\[(?<label>[^\]]*)\]\(\s*(?<target><[^>]+>|[^)\s]+)'
    )
    $links = [Collections.Generic.List[object]]::new()
    foreach ($match in $matches) {
        $resolvedPath = Get-MarkdownTarget -RawTarget $match.Groups['target'].Value -MarkdownPath $MarkdownPath -ContentRoot $ContentRoot -Label '本地链接'
        if ($resolvedPath) {
            $links.Add([pscustomobject]@{
                label = $match.Groups['label'].Value
                source = $match.Groups['target'].Value
                resolvedPath = $resolvedPath
                extension = [IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
            })
        }
    }
    return @($links)
}

function Get-MarkdownAssetReferences {
    param([Parameter(Mandatory)][string]$MarkdownPath, [Parameter(Mandatory)][string]$ContentRoot)
    $markdown = [IO.File]::ReadAllText($MarkdownPath)
    $matches = [Text.RegularExpressions.Regex]::Matches(
        $markdown,
        '!\[(?<label>[^\]]*)\]\(\s*(?<target><[^>]+>|[^)\s]+)'
    )
    $references = [Collections.Generic.List[object]]::new()
    foreach ($match in $matches) {
        $rawTarget = $match.Groups['target'].Value
        if ($rawTarget -match '^\s*<?(?i:https?)://') {
            throw "检测到尚未本地化的外部图片地址：$rawTarget"
        }
        $assetPath = Get-MarkdownTarget -RawTarget $rawTarget -MarkdownPath $MarkdownPath -ContentRoot $ContentRoot -Label '图片路径'
        if (-not $assetPath -or -not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
            throw "Notion 导出图片缺失：$rawTarget"
        }
        $references.Add([pscustomobject]@{
            label = $match.Groups['label'].Value
            source = $rawTarget
            resolvedPath = $assetPath
        })
    }
    return @($references)
}

function Get-MarkdownEntry {
    param([Parameter(Mandatory)][string]$ContentRoot, [string]$RequestedEntry)
    if (-not [string]::IsNullOrWhiteSpace($RequestedEntry)) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $ContentRoot $RequestedEntry))
        $candidate = Assert-PathInsideRoot -Root $ContentRoot -Path $candidate -Label 'EntryPath'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "找不到指定的 Markdown 入口：$RequestedEntry"
        }
        if ([IO.Path]::GetExtension($candidate) -ine '.md') {
            throw 'EntryPath 必须指向 Markdown 文件。'
        }
        return $candidate
    }

    $entries = @(Get-ChildItem -LiteralPath $ContentRoot -Recurse -File -Filter '*.md' | Sort-Object FullName)
    if ($entries.Count -eq 0) {
        throw '输入中没有找到 Markdown 文件。'
    }
    if ($entries.Count -eq 1) {
        return $entries[0].FullName
    }
    $referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        foreach ($link in @(Get-MarkdownLinks -MarkdownPath $entry.FullName -ContentRoot $ContentRoot)) {
            if ($link.extension -eq '.md' -and (Test-Path -LiteralPath $link.resolvedPath -PathType Leaf)) {
                [void]$referenced.Add($link.resolvedPath)
            }
        }
    }
    $roots = @($entries | Where-Object { -not $referenced.Contains($_.FullName) })
    if ($roots.Count -eq 1) {
        return $roots[0].FullName
    }
    $relativeEntries = $entries | ForEach-Object { Get-RelativePathCompat -Root $ContentRoot -Path $_.FullName }
    throw "无法唯一推断根页面，请使用 -EntryPath 指定入口：$($relativeEntries -join ', ')"
}

function Get-MarkdownDocuments {
    param([Parameter(Mandatory)][string]$Entry, [Parameter(Mandatory)][string]$ContentRoot)
    $pending = [Collections.Generic.Queue[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $documents = [Collections.Generic.List[object]]::new()
    $pending.Enqueue([pscustomobject]@{ path = $Entry; parent = $null; source = $null })
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        if (-not $seen.Add($current.path)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $current.path -PathType Leaf)) {
            throw "Notion 子页面缺失：$($current.source)"
        }
        $content = [IO.File]::ReadAllText($current.path)
        $links = @(Get-MarkdownLinks -MarkdownPath $current.path -ContentRoot $ContentRoot)
        $relativePath = Get-RelativePathCompat -Root $ContentRoot -Path $current.path
        $documents.Add([pscustomobject]@{
            path = $current.path
            relativePath = $relativePath
            parent = $current.parent
            source = $current.source
            content = $content
            links = $links
            bytes = (Get-Item -LiteralPath $current.path).Length
            characters = $content.Length
            sha256 = Get-Sha256 -Path $current.path
        })
        foreach ($link in $links) {
            if ($link.extension -eq '.md') {
                if (-not (Test-Path -LiteralPath $link.resolvedPath -PathType Leaf)) {
                    throw "Notion 子页面缺失：$($link.source)"
                }
                $pending.Enqueue([pscustomobject]@{
                    path = $link.resolvedPath
                    parent = $relativePath
                    source = $link.source
                })
            }
            elseif ($link.extension -and -not (Test-Path -LiteralPath $link.resolvedPath -PathType Leaf)) {
                throw "Notion 导出引用的本地文件缺失：$($link.source)"
            }
        }
    }
    return @($documents)
}

function Get-PageTitleFromPath {
    param([Parameter(Mandatory)][string]$Path)
    $title = [IO.Path]::GetFileNameWithoutExtension($Path)
    $title = $title -replace '\s+[0-9a-f]{32}$', ''
    if ([string]::IsNullOrWhiteSpace($title)) { return '未命名子页面' }
    return $title.Trim()
}

function Convert-HtmlFragmentToText {
    param([Parameter(Mandatory)][string]$Html)
    $text = [Text.RegularExpressions.Regex]::Replace($Html, '(?i)<br\s*/?>', [Environment]::NewLine)
    $text = [Text.RegularExpressions.Regex]::Replace($text, '(?i)</(p|div|li|h[1-6])>', [Environment]::NewLine)
    $text = [Text.RegularExpressions.Regex]::Replace($text, '<[^>]+>', '')
    $text = [Net.WebUtility]::HtmlDecode($text)
    $lines = @($text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return ($lines -join [Environment]::NewLine)
}

function Convert-ToQuote {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Prefix)
    $lines = @($Text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return "> $Prefix" }
    $quoted = [Collections.Generic.List[string]]::new()
    $quoted.Add("> $Prefix$($lines[0])")
    for ($index = 1; $index -lt $lines.Count; $index += 1) {
        $quoted.Add("> $($lines[$index])")
    }
    return ($quoted -join [Environment]::NewLine)
}

function Convert-DocumentContent {
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][hashtable]$AssetPathMap,
        [bool]$IsRoot
    )
    $converted = $Document.content
    $converted = [Text.RegularExpressions.Regex]::Replace(
        $converted,
        '!\[(?<label>[^\]]*)\]\(\s*(?<target><[^>]+>|[^)\s]+)\s*\)',
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $resolved = Get-MarkdownTarget -RawTarget $match.Groups['target'].Value -MarkdownPath $Document.path -ContentRoot $ContentRoot -Label '图片路径'
            if (-not $resolved -or -not $AssetPathMap.ContainsKey($resolved)) {
                throw "图片资源没有完成本地化：$($match.Groups['target'].Value)"
            }
            return "![$($match.Groups['label'].Value)]($($AssetPathMap[$resolved]))"
        }
    )
    $converted = [Text.RegularExpressions.Regex]::Replace(
        $converted,
        '(?is)<details\b[^>]*>(?<body>.*?)</details>',
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $body = $match.Groups['body'].Value
            $summaryMatch = [Text.RegularExpressions.Regex]::Match($body, '(?is)<summary\b[^>]*>(?<summary>.*?)</summary>')
            $summary = if ($summaryMatch.Success) {
                Convert-HtmlFragmentToText -Html $summaryMatch.Groups['summary'].Value
            }
            else { '未命名 Toggle' }
            $remaining = [Text.RegularExpressions.Regex]::Replace($body, '(?is)<summary\b[^>]*>.*?</summary>', '')
            $plainBody = Convert-HtmlFragmentToText -Html $remaining
            $text = if ([string]::IsNullOrWhiteSpace($plainBody)) {
                $summary
            }
            else { $summary + [Environment]::NewLine + $plainBody }
            return Convert-ToQuote -Text $text -Prefix 'Toggle（已展开）：'
        }
    )
    $converted = [Text.RegularExpressions.Regex]::Replace(
        $converted,
        '(?is)<aside\b[^>]*>(?<body>.*?)</aside>',
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $text = Convert-HtmlFragmentToText -Html $match.Groups['body'].Value
            return Convert-ToQuote -Text $text -Prefix 'Callout：'
        }
    )
    $converted = [Text.RegularExpressions.Regex]::Replace(
        $converted,
        '(?<!!)\[(?<label>[^\]]*)\]\(\s*(?<target><[^>]+>|[^)\s]+)\s*\)',
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $resolved = Get-MarkdownTarget -RawTarget $match.Groups['target'].Value -MarkdownPath $Document.path -ContentRoot $ContentRoot -Label '本地链接'
            if (-not $resolved) { return $match.Value }
            $label = $match.Groups['label'].Value
            if ([string]::IsNullOrWhiteSpace($label)) { $label = Get-PageTitleFromPath -Path $resolved }
            $extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
            if ($extension -eq '.md') { return "**子页面：$label（内容已附后）**" }
            if ($extension -eq '.csv') { return "**数据库：$label（已降级为 CSV 文件，数据未嵌入正文）**" }
            return "**附件：$label（未嵌入，请从原 Notion 导出包获取）**"
        }
    )
    if (-not $IsRoot) {
        $converted = [Text.RegularExpressions.Regex]::Replace(
            $converted,
            '(?m)^(#{1,5})(?=\s)',
            [Text.RegularExpressions.MatchEvaluator]{
                param($match)
                return $match.Groups[1].Value + '#'
            }
        )
        if ($converted -notmatch '(?m)^#{2,6}\s') {
            $title = Get-PageTitleFromPath -Path $Document.path
            $converted = "## $title" + [Environment]::NewLine + [Environment]::NewLine + $converted
        }
    }
    return $converted.Trim()
}

$failure = $null
try {
    $pandoc = Get-Command pandoc -ErrorAction SilentlyContinue
    if (-not $pandoc) { throw '未找到 Pandoc。请先安装 Pandoc，并确认 pandoc 位于 PATH。' }
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $temporaryRoot = Join-Path $temporaryBase ('notion2dingding-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    if (Test-Path -LiteralPath $resolvedInput -PathType Container) {
        $contentRoot = $resolvedInput
    }
    elseif (Test-Path -LiteralPath $resolvedInput -PathType Leaf) {
        if ([IO.Path]::GetExtension($resolvedInput) -ine '.zip') {
            throw '输入文件必须是 Notion 导出的 ZIP，或者传入已解压目录。'
        }
        $contentRoot = Join-Path $temporaryRoot 'export'
        [IO.Directory]::CreateDirectory($contentRoot) | Out-Null
        [IO.Compression.ZipFile]::ExtractToDirectory($resolvedInput, $contentRoot)
    }
    else { throw "输入路径不存在：$resolvedInput" }

    $markdownEntry = Get-MarkdownEntry -ContentRoot $contentRoot -RequestedEntry $EntryPath
    $documents = @(Get-MarkdownDocuments -Entry $markdownEntry -ContentRoot $contentRoot)
    $assetByPath = @{}
    $imageReferences = [Collections.Generic.List[object]]::new()
    $calloutCount = 0
    $toggleCount = 0
    $columnMarkupCount = 0
    $databaseByPath = @{}
    $attachmentCount = 0

    foreach ($document in $documents) {
        $calloutCount += [Text.RegularExpressions.Regex]::Matches($document.content, '(?is)<aside\b[^>]*>.*?</aside>').Count
        $toggleCount += [Text.RegularExpressions.Regex]::Matches($document.content, '(?is)<details\b[^>]*>.*?</details>').Count
        $columnMarkupCount += [Text.RegularExpressions.Regex]::Matches(
            $document.content,
            '(?is)(class\s*=\s*["''][^"'']*column|data-column)'
        ).Count
        foreach ($link in $document.links) {
            if ($link.extension -eq '.csv') {
                if (-not (Test-Path -LiteralPath $link.resolvedPath -PathType Leaf)) {
                    throw "Notion 数据库 CSV 缺失：$($link.source)"
                }
                if (-not $databaseByPath.ContainsKey($link.resolvedPath)) {
                    $databaseByPath[$link.resolvedPath] = [pscustomobject]@{
                        relativePath = Get-RelativePathCompat -Root $contentRoot -Path $link.resolvedPath
                        bytes = (Get-Item -LiteralPath $link.resolvedPath).Length
                        sha256 = Get-Sha256 -Path $link.resolvedPath
                    }
                }
            }
            elseif ($link.extension -and $link.extension -ne '.md') { $attachmentCount += 1 }
        }
        foreach ($reference in @(Get-MarkdownAssetReferences -MarkdownPath $document.path -ContentRoot $contentRoot)) {
            $imageReferences.Add([pscustomobject]@{
                document = $document.relativePath
                source = $reference.source
                resolvedPath = $reference.resolvedPath
            })
            if (-not $assetByPath.ContainsKey($reference.resolvedPath)) {
                $item = Get-Item -LiteralPath $reference.resolvedPath
                $assetByPath[$reference.resolvedPath] = [pscustomobject]@{
                    path = $reference.resolvedPath
                    relativePath = Get-RelativePathCompat -Root $contentRoot -Path $reference.resolvedPath
                    mime = Get-MimeType -Path $reference.resolvedPath
                    bytes = $item.Length
                    sha256 = Get-Sha256 -Path $reference.resolvedPath
                    referenceCount = 0
                    documents = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
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
    $hashTargetMap = @{}
    $assetPathMap = @{}
    foreach ($asset in $assetByPath.Values) {
        if (-not $hashTargetMap.ContainsKey($asset.sha256)) {
            $extension = [IO.Path]::GetExtension($asset.path).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.bin' }
            $relativeTarget = 'assets/' + $asset.sha256.ToLowerInvariant() + $extension
            $destination = Join-Path $temporaryRoot ($relativeTarget.Replace('/', '\'))
            Copy-Item -LiteralPath $asset.path -Destination $destination -Force
            $hashTargetMap[$asset.sha256] = $relativeTarget
        }
        $assetPathMap[$asset.path] = $hashTargetMap[$asset.sha256]
    }

    $preparedParts = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $documents.Count; $index += 1) {
        $preparedParts.Add((Convert-DocumentContent -Document $documents[$index] -ContentRoot $contentRoot -AssetPathMap $assetPathMap -IsRoot ($index -eq 0)))
    }
    $separator = [Environment]::NewLine + [Environment]::NewLine
    $combinedContent = $preparedParts -join $separator
    $preparedMarkdown = Join-Path $temporaryRoot 'combined.md'
    [IO.File]::WriteAllText($preparedMarkdown, $combinedContent, $utf8Encoding)

    $assets = @($assetByPath.Values | Sort-Object relativePath | ForEach-Object {
        [pscustomobject]@{
            relativePath = $_.relativePath
            localizedPath = $assetPathMap[$_.path]
            mime = $_.mime
            bytes = $_.bytes
            sha256 = $_.sha256
            referenceCount = $_.referenceCount
            documents = @($_.documents)
            sources = @($_.sources)
        }
    })
    $uniqueContentCount = @($hashTargetMap.Keys).Count
    $minimumImageCount = if ($ExpectedImageCount -ge 0) { $ExpectedImageCount } else { $uniqueContentCount }

    $warnings = [Collections.Generic.List[object]]::new()
    if ($documents.Count -gt 1) {
        $warnings.Add([pscustomobject]@{
            code = 'SUBPAGES_APPENDED'; severity = 'info'
            message = "已按链接顺序追加 $($documents.Count - 1) 个子页面，子页面标题层级下移一级。"
        })
    }
    if ($calloutCount -gt 0) {
        $warnings.Add([pscustomobject]@{
            code = 'CALLOUT_TO_BLOCKQUOTE'; severity = 'info'
            message = "已将 $calloutCount 个 Notion Callout HTML 块映射为带标识的引用块。"
        })
    }
    if ($toggleCount -gt 0) {
        $warnings.Add([pscustomobject]@{
            code = 'TOGGLE_EXPANDED'; severity = 'warning'
            message = "已将 $toggleCount 个 Toggle 展开为普通引用文本，折叠交互不会保留。"
        })
    }
    if ($databaseByPath.Count -gt 0) {
        $warnings.Add([pscustomobject]@{
            code = 'DATABASE_TO_CSV_NOTE'; severity = 'warning'
            message = "检测到 $($databaseByPath.Count) 个数据库 CSV；正文保留明确降级说明，数据库视图和交互不会迁移。"
        })
    }
    $warnings.Add([pscustomobject]@{
        code = 'COLUMNS_LINEARIZED_BY_EXPORT'; severity = 'info'
        message = 'Notion Markdown 导出不保留可靠的多栏布局元数据；内容按导出顺序线性排列。'
    })

    $outputDirectory = [IO.Path]::GetDirectoryName($resolvedOutput)
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    Write-Host "[1/3] 输入预检完成：$markdownEntry；文档 $($documents.Count)，图片引用 $($imageReferences.Count)"
    Write-Host "[2/3] 使用 Pandoc 生成 DOCX：$resolvedOutput"
    $pandocArguments = @(
        $preparedMarkdown,
        '--from=gfm',
        '--to=docx',
        '--standalone',
        "--resource-path=$temporaryRoot",
        "--output=$resolvedOutput"
    )
    & $pandoc.Source @pandocArguments
    if ($LASTEXITCODE -ne 0) { throw "Pandoc 转换失败，退出码：$LASTEXITCODE" }

    $verifyScript = Join-Path $PSScriptRoot 'test-docx-assets.ps1'
    Write-Host '[3/3] 验证 DOCX 正文与内嵌图片'
    $verifyArguments = @{
        DocxPath = $resolvedOutput
        ExpectedImageCount = $minimumImageCount
        RequiredText = $RequiredText
    }
    $verificationJson = & $verifyScript @verifyArguments
    $verification = $verificationJson | ConvertFrom-Json

    $documentOutput = @($documents | ForEach-Object {
        [pscustomobject]@{
            relativePath = $_.relativePath
            parent = $_.parent
            source = $_.source
            bytes = $_.bytes
            characters = $_.characters
            sha256 = $_.sha256
        }
    })
    $calloutStatus = if ($calloutCount -gt 0) { 'mapped' } else { 'not_present' }
    $toggleStatus = if ($toggleCount -gt 0) { 'degraded' } else { 'not_present' }
    $columnStatus = if ($columnMarkupCount -gt 0) { 'degraded' } else { 'source_flattened' }
    $databaseStatus = if ($databaseByPath.Count -gt 0) { 'degraded' } else { 'not_present' }

    Write-Host "转换成功：$resolvedOutput"
    [pscustomobject]@{
        success = $true
        input = $resolvedInput
        entry = Get-RelativePathCompat -Root $contentRoot -Path $markdownEntry
        output = $resolvedOutput
        documentCount = $documents.Count
        subpageCount = [Math]::Max(0, $documents.Count - 1)
        documents = $documentOutput
        sourceCharacters = ($documents | Measure-Object -Property characters -Sum).Sum
        preparedCharacters = $combinedContent.Length
        assetCount = $uniqueContentCount
        assets = $assets
        imageAudit = [pscustomobject]@{
            sourceReferenceCount = $imageReferences.Count
            localizedFileCount = $assetByPath.Count
            localizedAssetCount = $uniqueContentCount
            hashesComplete = @($assets | Where-Object { [string]::IsNullOrWhiteSpace($_.sha256) }).Count -eq 0
            allReferencesResolved = $true
            outputMediaCount = $verification.mediaCount
            outputImageOccurrenceCount = $verification.imageDrawingCount
            outputRelationshipCount = $verification.imageRelationshipCount
        }
        mappings = [pscustomobject]@{
            callout = [pscustomobject]@{
                detectedCount = $calloutCount; status = $calloutStatus
                output = '带 Callout 标识的引用块'
            }
            toggle = [pscustomobject]@{
                detectedCount = $toggleCount; status = $toggleStatus
                output = '展开后的引用文本'
            }
            columns = [pscustomobject]@{
                detectedMarkupCount = $columnMarkupCount; status = $columnStatus
                output = '按 Notion 导出顺序线性排列'
            }
            database = [pscustomobject]@{
                detectedCount = $databaseByPath.Count; status = $databaseStatus
                output = 'CSV 降级说明'
                files = @($databaseByPath.Values | Sort-Object relativePath)
            }
            attachments = [pscustomobject]@{
                detectedReferenceCount = $attachmentCount
                output = '附件降级说明'
            }
        }
        warnings = @($warnings)
        docx = $verification
    } | ConvertTo-Json -Depth 10
}
catch {
    $failure = [pscustomobject]@{
        success = $false
        error = [pscustomobject]@{
            code = 'CONVERSION_FAILED'
            message = $_.Exception.Message
            type = $_.Exception.GetType().FullName
        }
    }
}
finally {
    if ($temporaryRoot) {
        $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
        $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $temporaryName = [IO.Path]::GetFileName($resolvedTemporaryRoot)
        if (
            $resolvedTemporaryRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
            $temporaryName.StartsWith('notion2dingding-', [StringComparison]::Ordinal)
        ) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
if ($failure) {
    $failure | ConvertTo-Json -Depth 4 -Compress
    exit 1
}
