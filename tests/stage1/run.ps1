[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixtureRoot = Join-Path $repoRoot 'tests\fixtures\notion-export'
$artifactRoot = Join-Path $repoRoot 'artifacts\stage1'
$convertScript = Join-Path $repoRoot 'scripts\convert-notion-export.ps1'
$directoryOutput = Join-Path $artifactRoot 'notion-stage1-directory.docx'
$zipOutput = Join-Path $artifactRoot 'notion-stage1-zip.docx'
$temporaryZip = Join-Path ([IO.Path]::GetTempPath()) ('notion2dingding-fixture-' + [Guid]::NewGuid().ToString('N') + '.zip')

[IO.Directory]::CreateDirectory($artifactRoot) | Out-Null

try {
    Write-Host '=== 使用目录输入验证 ==='
    & $convertScript `
        -InputPath $fixtureRoot `
        -OutputPath $directoryOutput `
        -ExpectedImageCount 2 `
        -RequiredText @('阶段 1 验证页面', '图片一', '图片二')

    Write-Host '=== 使用 ZIP 输入验证 ==='
    [IO.Compression.ZipFile]::CreateFromDirectory($fixtureRoot, $temporaryZip)
    & $convertScript `
        -InputPath $temporaryZip `
        -OutputPath $zipOutput `
        -ExpectedImageCount 2 `
        -RequiredText @('阶段 1 验证页面', '图片一', '图片二')

    [pscustomobject]@{
        success         = $true
        directoryOutput = $directoryOutput
        zipOutput       = $zipOutput
    } | ConvertTo-Json
}
finally {
    $resolvedTemporaryZip = [IO.Path]::GetFullPath($temporaryZip)
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (
        $resolvedTemporaryZip.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedTemporaryZip).StartsWith('notion2dingding-fixture-', [StringComparison]::Ordinal)
    ) {
        Remove-Item -LiteralPath $resolvedTemporaryZip -Force -ErrorAction SilentlyContinue
    }
}
