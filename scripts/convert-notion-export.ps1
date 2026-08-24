[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputPath,

    [string]$OutputPath,

    [string]$EntryPath,

    [int]$ExpectedImageCount = 0,

    [string[]]$RequiredText = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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

function Get-MarkdownEntry {
    param(
        [Parameter(Mandatory)]
        [string]$ContentRoot,

        [string]$RequestedEntry
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedEntry)) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $ContentRoot $RequestedEntry))
        $normalizedRoot = [IO.Path]::GetFullPath($ContentRoot).TrimEnd('\') + '\'
        if (-not $candidate.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'EntryPath 不能指向输入目录之外。'
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "找不到指定的 Markdown 入口：$RequestedEntry"
        }
        return $candidate
    }

    $entries = @(Get-ChildItem -LiteralPath $ContentRoot -Recurse -File -Filter '*.md')
    if ($entries.Count -eq 0) {
        throw '输入中没有找到 Markdown 文件。'
    }
    if ($entries.Count -gt 1) {
        $normalizedRoot = [IO.Path]::GetFullPath($ContentRoot).TrimEnd('\') + '\'
        $relativeEntries = $entries | ForEach-Object {
            if ($_.FullName.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $_.FullName.Substring($normalizedRoot.Length)
            }
            else {
                $_.FullName
            }
        }
        throw "输入包含多个 Markdown 文件，请使用 -EntryPath 指定入口：$($relativeEntries -join ', ')"
    }
    return $entries[0].FullName
}

try {
    $pandoc = Get-Command pandoc -ErrorAction SilentlyContinue
    if (-not $pandoc) {
        throw '未找到 Pandoc。请先安装 Pandoc，并确认 pandoc 位于 PATH。'
    }

    if (Test-Path -LiteralPath $resolvedInput -PathType Container) {
        $contentRoot = $resolvedInput
    }
    elseif (Test-Path -LiteralPath $resolvedInput -PathType Leaf) {
        if ([IO.Path]::GetExtension($resolvedInput) -ine '.zip') {
            throw '输入文件必须是 Notion 导出的 ZIP，或者传入已解压目录。'
        }

        $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $temporaryRoot = Join-Path $temporaryBase ('notion2dingding-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
        [IO.Compression.ZipFile]::ExtractToDirectory($resolvedInput, $temporaryRoot)
        $contentRoot = $temporaryRoot
    }
    else {
        throw "输入路径不存在：$resolvedInput"
    }

    $markdownEntry = Get-MarkdownEntry -ContentRoot $contentRoot -RequestedEntry $EntryPath
    $entryDirectory = [IO.Path]::GetDirectoryName($markdownEntry)
    $resourcePath = @($entryDirectory, $contentRoot) -join [IO.Path]::PathSeparator

    $outputDirectory = [IO.Path]::GetDirectoryName($resolvedOutput)
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null

    Write-Host "[1/3] 输入预检完成：$markdownEntry"
    Write-Host "[2/3] 使用 Pandoc 生成 DOCX：$resolvedOutput"

    & $pandoc.Source $markdownEntry `
        '--from=gfm' `
        '--to=docx' `
        '--standalone' `
        "--resource-path=$resourcePath" `
        "--output=$resolvedOutput"
    if ($LASTEXITCODE -ne 0) {
        throw "Pandoc 转换失败，退出码：$LASTEXITCODE"
    }

    $verifyScript = Join-Path $PSScriptRoot 'test-docx-assets.ps1'
    Write-Host '[3/3] 验证 DOCX 正文与内嵌图片'
    & $verifyScript `
        -DocxPath $resolvedOutput `
        -ExpectedImageCount $ExpectedImageCount `
        -RequiredText $RequiredText

    Write-Host "转换成功：$resolvedOutput"
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
