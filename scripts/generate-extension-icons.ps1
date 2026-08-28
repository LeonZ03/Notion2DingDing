Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 主图由用户提供的 Notion 与钉钉图形作为参考，经 OpenAI 内置图像生成工具重新组合。
# icon-master-v2.png 是本项目的生成资产；脚本只做确定性高质量缩放，不再用代码重画品牌图形。
Add-Type -AssemblyName System.Drawing
[void][Reflection.Assembly]::LoadWithPartialName('System.Drawing')

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputDirectory = Join-Path $repositoryRoot 'apps\edge-extension\public\icons'
$storeOutputDirectory = Join-Path $repositoryRoot 'assets\edge-store'
$masterPath = Join-Path $repositoryRoot 'assets\extension-icon\icon-master-v2.png'
if (-not (Test-Path -LiteralPath $masterPath -PathType Leaf)) {
    throw "缺少图标主图：$masterPath"
}

$source = [System.Drawing.Image]::FromFile($masterPath)
try {
    $targets = @(
        foreach ($size in @(16, 32, 48, 128)) {
            [pscustomobject]@{ Size = $size; Path = Join-Path $outputDirectory "icon-$size.png" }
        }
        [pscustomobject]@{ Size = 300; Path = Join-Path $storeOutputDirectory 'extension-logo-300.png' }
    )
    foreach ($target in $targets) {
        $size = [int]$target.Size
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target.Path)) | Out-Null
        $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage($source, 0, 0, $size, $size)
            $bitmap.Save($target.Path, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
}
finally {
    $source.Dispose()
}

[ordered]@{
    success = $true
    master = $masterPath
    sizes = @(16, 32, 48, 128)
    storeLogo = Join-Path $storeOutputDirectory 'extension-logo-300.png'
    source = 'User-provided Notion and DingTalk references, recomposed with OpenAI built-in image generation'
} | ConvertTo-Json -Depth 3
