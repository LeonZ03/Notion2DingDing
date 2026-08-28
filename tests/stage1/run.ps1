[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixtureRoot = Join-Path $repoRoot 'tests\fixtures\notion-export'
$convertScript = Join-Path $repoRoot 'scripts\convert-notion-export.ps1'
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$runRoot = Join-Path $temporaryBase ('notion2dingding-stage1-' + [Guid]::NewGuid().ToString('N'))
$directoryOutput = Join-Path $runRoot 'notion-stage1-directory.docx'
$zipOutput = Join-Path $runRoot 'notion-stage1-zip.docx'
$temporaryZip = Join-Path $runRoot 'notion-stage1-fixture.zip'
$completed = $false

[IO.Directory]::CreateDirectory($runRoot) | Out-Null

try {
    Write-Host '=== 使用目录输入验证 ==='
    $directoryJson = & $convertScript `
        -InputPath $fixtureRoot `
        -OutputPath $directoryOutput `
        -ExpectedImageCount 2 `
        -RequiredText @('图片一', '图片二')
    $directoryResult = $directoryJson | ConvertFrom-Json
    if ($directoryResult.mappings.documentTitle.duplicateTitleBlockCount -ne 0) {
        throw '目录输入生成的 DOCX 正文仍包含重复根页面标题。'
    }

    Write-Host '=== 使用 ZIP 输入验证 ==='
    [IO.Compression.ZipFile]::CreateFromDirectory($fixtureRoot, $temporaryZip)
    $zipJson = & $convertScript `
        -InputPath $temporaryZip `
        -OutputPath $zipOutput `
        -ExpectedImageCount 2 `
        -RequiredText @('图片一', '图片二')
    $zipResult = $zipJson | ConvertFrom-Json
    if ($zipResult.mappings.documentTitle.duplicateTitleBlockCount -ne 0) {
        throw 'ZIP 输入生成的 DOCX 正文仍包含重复根页面标题。'
    }

    $completed = $true
}
finally {
    $resolvedRunRoot = [IO.Path]::GetFullPath($runRoot).TrimEnd('\')
    if (
        $resolvedRunRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRunRoot).StartsWith('notion2dingding-stage1-', [StringComparison]::Ordinal)
    ) {
        Remove-Item -LiteralPath $resolvedRunRoot -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $resolvedRunRoot) {
            throw "阶段 1 临时数据未能永久删除：$resolvedRunRoot"
        }
    }
    else {
        throw "拒绝清理未通过边界校验的阶段 1 路径：$resolvedRunRoot"
    }
}

[pscustomobject]@{
    success           = $completed
    cleanupPermanent  = $true
    cleanupVerified   = $true
} | ConvertTo-Json
