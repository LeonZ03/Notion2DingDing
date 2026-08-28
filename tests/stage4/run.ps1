[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$installer = Join-Path $repoRoot 'scripts\install-local-tool.ps1'
$fixture = Join-Path $repoRoot 'tests\fixtures\notion-export'
$layoutFixture = Join-Path $repoRoot 'tests\fixtures\notion-html-layout'
$fakeDws = Join-Path $repoRoot 'tests\stage2\fake-dws.mjs'
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$runRoot = Join-Path $temporaryBase ('notion2dingding-stage4-' + [Guid]::NewGuid().ToString('N'))
$installDirectory = Join-Path $runRoot 'user\Programs\Notion2DingDing'
$dataDirectory = Join-Path $runRoot 'user\AppData\Local\Notion2DingDing'
$launcherDirectory = Join-Path $runRoot 'user\AppData\Local\Microsoft\WindowsApps'
$launcherPath = Join-Path $launcherDirectory 'n2dd.cmd'
$startMenuDirectory = Join-Path $runRoot 'user\AppData\Roaming\Microsoft\Windows\Start Menu\Programs'
$shortcutDirectory = Join-Path $startMenuDirectory 'Notion2DingDing'
$shortcutPath = Join-Path $shortcutDirectory 'Notion2DingDing.lnk'
$foreignPath = Join-Path $runRoot 'foreign.keep'
$dwsLog = Join-Path $runRoot 'fake-dws-calls.jsonl'
$runtimeFakeDws = Join-Path $runRoot 'fake-dws.mjs'
$fakeNpmRoot = Join-Path $runRoot 'fake-npm'
$fakeNpmDws = Join-Path $fakeNpmRoot 'dws.ps1'
$fakeNpmPackage = Join-Path $fakeNpmRoot 'node_modules\dingtalk-workspace-cli'
$fakeNpmDwsEntry = Join-Path $fakeNpmPackage 'bin\dws.js'
$fixtureFile = (Get-ChildItem -LiteralPath $fixture -File | Select-Object -First 1).FullName
$guiSource = Join-Path $repoRoot 'scripts\notion2dingding-gui.ps1'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Get-FileSha256 {
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

$fixtureHashBefore = Get-FileSha256 -Path $fixtureFile
$originalPath = $env:PATH

function Invoke-JsonScript {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$ExpectedExitCode = 0
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>$null | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne $ExpectedExitCode) {
        throw "脚本退出码不符合预期：$Script，实际 $exitCode，预期 $ExpectedExitCode，输出：$output"
    }
    try {
        return $output | ConvertFrom-Json
    }
    catch {
        throw "脚本没有返回有效 JSON：$Script，输出：$output"
    }
}

function Invoke-LauncherJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$ExpectedExitCode = 0
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $launcherPath @Arguments 2>$null | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne $ExpectedExitCode) {
        throw "n2dd 退出码不符合预期：实际 $exitCode，预期 $ExpectedExitCode，输出：$output"
    }
    try {
        return $output | ConvertFrom-Json
    }
    catch {
        throw "n2dd 没有返回有效 JSON，输出：$output"
    }
}

try {
    $guiTokens = $null
    $guiParseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($guiSource, [ref]$guiTokens, [ref]$guiParseErrors) | Out-Null
    Assert-True -Condition ($guiParseErrors.Count -eq 0) -Message ('一键界面存在 PowerShell 语法错误：' + ($guiParseErrors -join '；'))

    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    Copy-Item -LiteralPath $fakeDws -Destination $runtimeFakeDws -Force
    [IO.Directory]::CreateDirectory((Split-Path -Parent $fakeNpmDwsEntry)) | Out-Null
    Copy-Item -LiteralPath $fakeDws -Destination $fakeNpmDwsEntry -Force
    [IO.File]::WriteAllText(
        (Join-Path $fakeNpmPackage 'package.json'),
        '{"type":"module"}',
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        $fakeNpmDws,
        '& node.exe "$PSScriptRoot\node_modules\dingtalk-workspace-cli\bin\dws.js" @args' + "`r`n" + 'exit $LASTEXITCODE' + "`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText($foreignPath, '不属于 Notion2DingDing 的文件', [Text.UTF8Encoding]::new($false))

    $install = Invoke-JsonScript -Script $installer -Arguments @(
        '-Action', 'Install',
        '-InstallDirectory', $installDirectory,
        '-DataDirectory', $dataDirectory,
        '-LauncherDirectory', $launcherDirectory,
        '-StartMenuDirectory', $startMenuDirectory,
        '-SkipDependencyCheck'
    )
    Assert-True -Condition ($install.success -eq $true) -Message '首次安装必须成功。'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $installDirectory '.n2dd-install.json')) -Message '安装所有权标记不存在。'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $dataDirectory '.n2dd-data.json')) -Message '数据所有权标记不存在。'
    Assert-True -Condition (Test-Path -LiteralPath $launcherPath) -Message 'n2dd 启动器不存在。'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $shortcutDirectory '.n2dd-shortcut.json')) -Message '开始菜单快捷方式所有权标记不存在。'
    Assert-True -Condition (Test-Path -LiteralPath $shortcutPath) -Message '开始菜单一键入口不存在。'

    $shortcutShell = $null
    $installedShortcut = $null
    try {
        $shortcutShell = New-Object -ComObject WScript.Shell
        $installedShortcut = $shortcutShell.CreateShortcut($shortcutPath)
        Assert-True -Condition ($installedShortcut.TargetPath -eq $wscriptPath) -Message '开始菜单入口没有使用无控制台窗口启动器。'
        Assert-True -Condition ($installedShortcut.Arguments -like '*launch-notion2dingding-gui.vbs*') -Message '开始菜单入口没有启动一键界面。'
        Assert-True -Condition ($installedShortcut.WorkingDirectory -eq $dataDirectory) -Message '开始菜单入口错误占用了程序目录，可能阻塞升级。'
        $installedVbsPath = Join-Path $installDirectory 'cli\launch-notion2dingding-gui.vbs'
        Assert-True -Condition (Test-Path -LiteralPath $installedVbsPath) -Message '安装目录缺少一键界面启动器。'
        $installedVbs = Get-Content -LiteralPath $installedVbsPath -Raw
        Assert-True -Condition ($installedVbs -like '*-WindowStyle Hidden*') -Message '一键入口没有隐藏 PowerShell 控制台。'
        Assert-True -Condition ($installedVbs -like '*shell.Run command, 1, False*') -Message '一键入口会错误隐藏 WinForms 窗口。'
        Assert-True -Condition ($installedVbs -like '*shell.CurrentDirectory*%LOCALAPPDATA%*Notion2DingDing*') -Message '一键入口没有把子进程工作目录迁出程序目录。'
    }
    finally {
        if ($installedShortcut) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installedShortcut) | Out-Null }
        if ($shortcutShell) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcutShell) | Out-Null }
    }

    $installedGui = Join-Path $installDirectory 'cli\notion2dingding-gui.ps1'
    $guiSelfTest = Invoke-JsonScript -Script $installedGui -Arguments @('-SelfTest')
    Assert-True -Condition ($guiSelfTest.windowsForms -eq $true) -Message '一键界面未能加载 Windows Forms。'
    Assert-True -Condition ($guiSelfTest.supportsDragDrop -eq $true) -Message '一键界面未启用拖入导出包。'
    Assert-True -Condition ($guiSelfTest.controls -contains 'StartMigration') -Message '一键界面缺少开始转换按钮。'
    Assert-True -Condition ($guiSelfTest.controls -contains 'DocumentLink') -Message '一键界面缺少结果文档链接。'
    Assert-True -Condition ($guiSelfTest.controls -contains 'SelectDingTalkFolder') -Message '一键界面缺少钉钉文件夹选择按钮。'
    Assert-True -Condition ($guiSelfTest.controls -contains 'SubpageMode') -Message '一键界面缺少子页面处理方式选择。'
    Assert-True -Condition ($guiSelfTest.defaultSubpageMode -eq 'inline') -Message '一键界面的默认子页面方式必须是在同页面内展开。'
    Assert-True -Condition ($guiSelfTest.eventHandlersReady -eq $true) -Message '一键界面的事件回调无法读取窗口状态。'
    Assert-True -Condition ($guiSelfTest.eventChecks.StartMigration -eq $true) -Message '开始转换按钮事件没有通过作用域自检。'
    Assert-True -Condition ($guiSelfTest.eventChecks.SelectDingTalkFolder -eq $true) -Message '钉钉文件夹选择按钮事件没有通过作用域自检。'
    Assert-True -Condition ($guiSelfTest.openActionReady -eq $true) -Message 'Edge 打开钉钉文件夹选择器的自动触发事件没有通过自检。'

    $titleSource = Join-Path $runRoot 'title-source'
    $titleChildDirectory = Join-Path $titleSource '真正的 Notion 标题 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    [IO.Directory]::CreateDirectory($titleChildDirectory) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $titleSource '真正的 Notion 标题 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.html'),
        '<!doctype html><html><head><meta charset="utf-8"><title>真正的 Notion 标题</title></head><body><h1 class="page-title">真正的 Notion 标题</h1><p>正文。</p><a href="真正的%20Notion%20标题%20aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/子页面%20bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.html">子页面</a></body></html>',
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $titleChildDirectory '子页面 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.html'),
        '<!doctype html><html><head><meta charset="utf-8"><title>子页面</title></head><body><h1 class="page-title">子页面</h1></body></html>',
        [Text.UTF8Encoding]::new($false)
    )
    $titleInnerZip = Join-Path $runRoot 'ExportBlock-12345678-1234-1234-1234-123456789abc-Part-1.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($titleSource, $titleInnerZip)
    $titleWrapper = Join-Path $runRoot 'title-wrapper'
    [IO.Directory]::CreateDirectory($titleWrapper) | Out-Null
    Copy-Item -LiteralPath $titleInnerZip -Destination $titleWrapper
    $randomZip = Join-Path $runRoot '_ExportBlock-12345678-1234-1234-1234-123456789abc.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($titleWrapper, $randomZip)
    $inferredTitle = Invoke-JsonScript -Script $installedGui -Arguments @('-InferTitle', '-InputPath', $randomZip)
    Assert-True -Condition ($inferredTitle.title -eq '真正的 Notion 标题') -Message '界面标题仍错误使用 ZIP 名或未移除 Notion 页面 ID。'

    $headingSource = Join-Path $runRoot 'heading-source'
    [IO.Directory]::CreateDirectory($headingSource) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $headingSource 'cccccccccccccccccccccccccccccccc.html'),
        '<!doctype html><html><head><meta charset="utf-8"><title>从 HTML 标题读取的页面名</title></head><body><p>正文</p></body></html>',
        [Text.UTF8Encoding]::new($false)
    )
    $headingTitle = Invoke-JsonScript -Script $installedGui -Arguments @('-InferTitle', '-InputPath', $headingSource)
    Assert-True -Condition ($headingTitle.title -eq '从 HTML 标题读取的页面名') -Message '根页面文件名只有 ID 时未使用 HTML title 兜底。'

    $markdownOnly = Join-Path $runRoot 'markdown-only'
    [IO.Directory]::CreateDirectory($markdownOnly) | Out-Null
    [IO.File]::WriteAllText((Join-Path $markdownOnly '旧格式.md'), '# 旧格式', [Text.UTF8Encoding]::new($false))
    $markdownRejected = Invoke-JsonScript -Script $installedGui -Arguments @('-InferTitle', '-InputPath', $markdownOnly) -ExpectedExitCode 1
    Assert-True -Condition ($markdownRejected.success -eq $false) -Message 'HTML-only 模式错误接受了 Markdown 导出。'
    Assert-True -Condition ([string]$markdownRejected.error -match '只支持 HTML') -Message '拒绝 Markdown 时没有给出重新导出 HTML 的提示。'

    $missingCommand = Join-Path $runRoot 'missing-tool.exe'
    $doctorScript = Join-Path $installDirectory 'cli\diagnose-local-tool.ps1'
    $missingDoctor = Invoke-JsonScript -Script $doctorScript -Arguments @(
        '-DataDirectory', $dataDirectory,
        '-NodeCommand', $missingCommand,
        '-PandocCommand', $missingCommand,
        '-DwsCommand', $missingCommand,
        '-NoExitCode'
    )
    Assert-True -Condition ($missingDoctor.ready -eq $false) -Message '依赖全缺失时 doctor 不得报告就绪。'
    Assert-True -Condition ($missingDoctor.fixes -contains 'winget install OpenJS.NodeJS') -Message '缺少 Node.js 时未给出安装命令。'
    Assert-True -Condition ($missingDoctor.fixes -contains 'winget install JohnMacFarlane.Pandoc') -Message '缺少 Pandoc 时未给出安装命令。'
    Assert-True -Condition ($missingDoctor.fixes -contains 'npm install -g dingtalk-workspace-cli@1.0.59') -Message '缺少 dws 时未给出安装命令。'
    Assert-True -Condition ($missingDoctor.fixes -contains 'dws auth login') -Message '缺少登录状态时未给出登录命令。'

    $env:N2DD_FAKE_SCENARIO = 'success'
    $env:N2DD_FAKE_LOG = $dwsLog
    $nodePath = (Get-Command node -ErrorAction Stop).Source
    $pandocPath = (Get-Command pandoc.exe -ErrorAction Stop).Source
    $readyDoctor = Invoke-LauncherJson -Arguments @(
        'doctor',
        '-NodeCommand', $nodePath,
        '-PandocCommand', $pandocPath,
        '-DwsCommand', $fakeNpmDws,
        '-NoExitCode'
    )
    Assert-True -Condition ($readyDoctor.ready -eq $true) -Message '依赖和登录均有效时 doctor 应报告就绪。'

    $installedConverter = Join-Path $installDirectory 'runtime\scripts\convert-notion-export.ps1'
    Add-Type -AssemblyName System.Drawing
    $optimizationFixture = Join-Path $runRoot 'image-optimization-fixture'
    [IO.Directory]::CreateDirectory($optimizationFixture) | Out-Null
    $optimizationImage = Join-Path $optimizationFixture 'noise.png'
    $bitmap = [Drawing.Bitmap]::new(512, 512, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $bitmapData = $null
    try {
        $rectangle = [Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height)
        $bitmapData = $bitmap.LockBits($rectangle, [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $pixelBytes = New-Object byte[] ([Math]::Abs($bitmapData.Stride) * $bitmapData.Height)
        [Random]::new(20260825).NextBytes($pixelBytes)
        [Runtime.InteropServices.Marshal]::Copy($pixelBytes, 0, $bitmapData.Scan0, $pixelBytes.Length)
        $bitmap.UnlockBits($bitmapData)
        $bitmapData = $null
        $bitmap.Save($optimizationImage, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($bitmapData) { $bitmap.UnlockBits($bitmapData) }
        $bitmap.Dispose()
    }
    [IO.File]::WriteAllText(
        (Join-Path $optimizationFixture '图片优化验证 88888888888888888888888888888888.html'),
        '<!doctype html><html><head><meta charset="utf-8"><title>图片优化验证</title></head><body><h1 class="page-title">图片优化验证</h1><p>OPTIMIZE-FINAL</p><img src="noise.png"></body></html>',
        [Text.UTF8Encoding]::new($false)
    )
    $optimizationOutput = Join-Path $runRoot 'image-optimization.docx'
    $optimizationJson = & $installedConverter `
        -InputPath $optimizationFixture `
        -OutputPath $optimizationOutput `
        -ExpectedImageCount 1 `
        -RequiredText @('OPTIMIZE-FINAL') `
        -ImageOptimizationTriggerBytes 1 `
        -ImageOptimizationMinimumPngBytes 1
    $optimization = $optimizationJson | ConvertFrom-Json
    Assert-True -Condition ($optimization.success -eq $true) -Message '大体积 PNG 优化夹具转换失败。'
    Assert-True -Condition ($optimization.imageAudit.optimizedAssetCount -eq 1) -Message '大体积 PNG 没有进入临时优化分支。'
    Assert-True -Condition ($optimization.imageAudit.localizedAssetBytes -lt $optimization.imageAudit.sourceAssetBytes) -Message '临时图片优化没有降低资源体积。'
    Assert-True -Condition ($optimization.docx.mediaCount -eq 1) -Message '图片优化后 DOCX 媒体数量不一致。'
    Assert-True -Condition ($optimization.docx.externalImageRelationships -eq 0) -Message '图片优化后出现外部图片关系。'
    Remove-Item -LiteralPath $optimizationOutput -Force
    Assert-True -Condition (-not (Test-Path -LiteralPath $optimizationOutput)) -Message '图片优化验收 DOCX 未被永久删除。'

    $singleImageFixture = Join-Path $runRoot 'single-image-fixture'
    [IO.Directory]::CreateDirectory($singleImageFixture) | Out-Null
    Copy-Item -LiteralPath (Join-Path $layoutFixture '红色 示意图.png') -Destination (Join-Path $singleImageFixture '单图.png')
    [IO.File]::WriteAllText(
        (Join-Path $singleImageFixture '单图无表格验证 ffffffffffffffffffffffffffffffff.html'),
        @'
<!doctype html><html><head><meta charset="utf-8"><title>单图无表格验证</title></head><body>
<h1 class="page-title">单图无表格验证</h1>
<p>SINGLE-IMAGE-START</p>
<a href="https://example.com/bookmark" class="bookmark source">
  <div><img src="https://cdn.example.com/favicon.ico"><span>BOOKMARK-PRESERVED</span><img src="//cdn.example.com/thumbnail.png"></div>
</a>
<figure class="image"><img src="单图.png" alt="普通单图"></figure>
<div class="column-list" notion-column-list>
  <div class="column" style="width:100%" notion-column-ratio="1">
    <figure class="image"><img src="单图.png" alt="单列容器中的图片"></figure>
  </div>
</div>
<p>SINGLE-IMAGE-FINAL</p></body></html>
'@,
        [Text.UTF8Encoding]::new($false)
    )
    $singleImageOutput = Join-Path $runRoot 'single-image.docx'
    $singleImageJson = & $installedConverter `
        -InputPath $singleImageFixture `
        -OutputPath $singleImageOutput `
        -ExpectedImageCount 1 `
        -RequiredText @('BOOKMARK-PRESERVED', 'SINGLE-IMAGE-FINAL')
    $singleImage = $singleImageJson | ConvertFrom-Json
    Assert-True -Condition ($singleImage.success -eq $true) -Message '普通单图与单列容器夹具转换失败。'
    Assert-True -Condition ($singleImage.mappings.columns.detectedListCount -eq 1) -Message '单列容器没有被识别。'
    Assert-True -Condition ($singleImage.mappings.columns.singleColumnListCount -eq 1) -Message '单列容器没有直接输出。'
    Assert-True -Condition ($singleImage.mappings.columns.outputLayoutTableCount -eq 0) -Message '单列容器错误生成了布局表。'
    Assert-True -Condition ($singleImage.mappings.bookmark.detectedCount -eq 1) -Message 'Notion 书签卡片没有被识别。'
    Assert-True -Condition ($singleImage.mappings.bookmark.omittedExternalPreviewImageCount -eq 2) -Message '书签中的两个外部装饰图没有被精确省略。'
    Assert-True -Condition ($singleImage.mappings.bookmark.status -eq 'degraded') -Message '省略外部书签预览图后没有报告显式降级。'
    Assert-True -Condition (@($singleImage.warnings | Where-Object { $_.code -eq 'BOOKMARK_EXTERNAL_PREVIEW_OMITTED' }).Count -eq 1) -Message '缺少外部书签预览图省略说明。'
    Assert-True -Condition ($singleImage.imageAudit.sourceReferenceCount -eq 2) -Message '书签装饰图被错误计入正文图片审计。'
    Assert-True -Condition ($singleImage.docx.externalImageRelationships -eq 0) -Message 'DOCX 仍包含书签站点的外部图片关系。'
    Assert-True -Condition ($singleImage.layout.pageOrientation -eq 'portrait') -Message '只有单图的文档不应切换为横向页面。'

    $singleImageArchive = [IO.Compression.ZipFile]::OpenRead($singleImageOutput)
    try {
        $singleImageEntry = $singleImageArchive.GetEntry('word/document.xml')
        Assert-True -Condition ($null -ne $singleImageEntry) -Message '单图 DOCX 缺少 document.xml。'
        $singleImageReader = [IO.StreamReader]::new($singleImageEntry.Open(), [Text.Encoding]::UTF8, $true)
        try { [xml]$singleImageXml = $singleImageReader.ReadToEnd() } finally { $singleImageReader.Dispose() }
        $singleImageNamespaces = [Xml.XmlNamespaceManager]::new($singleImageXml.NameTable)
        $singleImageNamespaces.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        Assert-True -Condition (@($singleImageXml.SelectNodes('//w:drawing', $singleImageNamespaces)).Count -eq 2) -Message '两处单图没有全部保留。'
        Assert-True -Condition (@($singleImageXml.SelectNodes('//w:tbl', $singleImageNamespaces)).Count -eq 0) -Message '普通单图或单列图片仍被包装为 1×1 表格。'
    }
    finally {
        $singleImageArchive.Dispose()
    }
    Remove-Item -LiteralPath $singleImageOutput -Force
    Assert-True -Condition (-not (Test-Path -LiteralPath $singleImageOutput)) -Message '单图验收 DOCX 未被永久删除。'

    $externalImageFixture = Join-Path $runRoot 'external-image-fixture'
    [IO.Directory]::CreateDirectory($externalImageFixture) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $externalImageFixture '正文外链图片拒绝验证 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.html'),
        '<!doctype html><html><head><meta charset="utf-8"><title>正文外链图片拒绝验证</title></head><body><h1 class="page-title">正文外链图片拒绝验证</h1><figure class="image"><img src="https://cdn.example.com/content.png"></figure></body></html>',
        [Text.UTF8Encoding]::new($false)
    )
    $externalImageOutput = Join-Path $runRoot 'external-image.docx'
    $externalImageFailure = Invoke-JsonScript -Script $installedConverter -Arguments @(
        '-InputPath', $externalImageFixture,
        '-OutputPath', $externalImageOutput
    ) -ExpectedExitCode 1
    Assert-True -Condition ($externalImageFailure.success -eq $false) -Message '书签外的正文外链图片不应转换成功。'
    Assert-True -Condition ($externalImageFailure.error.message -match '尚未本地化的外部图片地址') -Message '正文外链图片没有返回明确错误。'
    Assert-True -Condition (-not (Test-Path -LiteralPath $externalImageOutput)) -Message '正文外链图片失败后不应残留 DOCX。'

    $layoutOutput = Join-Path $runRoot 'html-layout.docx'
    $layoutJson = & $installedConverter `
        -InputPath $layoutFixture `
        -OutputPath $layoutOutput `
        -ExpectedImageCount 2 `
        -RequiredText @('LAYOUT-FINAL')
    $layoutConversion = $layoutJson | ConvertFrom-Json
    Assert-True -Condition ($layoutConversion.success -eq $true) -Message 'HTML 多栏夹具转换失败。'
    Assert-True -Condition (($layoutConversion.mappings.columns.tableSequence.kind -join ',') -eq 'layout,layout,data') -Message 'DOCX 没有按顺序标记两个布局表和一个真实数据表。'
    Assert-True -Condition (($layoutConversion.mappings.columns.tableSequence.columnCount -join ',') -eq '3,2,2') -Message 'DOCX 表格序列的列数审计不一致。'
    Assert-True -Condition (Test-Path -LiteralPath $layoutOutput -PathType Leaf) -Message 'HTML 多栏夹具没有生成 DOCX。'

    $layoutArchive = [IO.Compression.ZipFile]::OpenRead($layoutOutput)
    try {
        $documentEntry = $layoutArchive.GetEntry('word/document.xml')
        Assert-True -Condition ($null -ne $documentEntry) -Message '多栏 DOCX 缺少 document.xml。'
        $reader = [IO.StreamReader]::new($documentEntry.Open(), [Text.Encoding]::UTF8, $true)
        try { [xml]$layoutXml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $namespaces = [Xml.XmlNamespaceManager]::new($layoutXml.NameTable)
        $namespaces.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        $namespaces.AddNamespace('wp', 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing')
        $layoutTables = @($layoutXml.SelectNodes("//w:tbl[w:tblPr/w:tblStyle[@w:val='Notion Columns']]", $namespaces))
        Assert-True -Condition ($layoutTables.Count -eq 2) -Message 'HTML 的两个多栏行没有一一映射为 DOCX 布局行。'
        $threeImagesFound = $false
        $mixedRowFound = $false
        foreach ($table in $layoutTables) {
            $borders = @($table.SelectNodes('./w:tblPr/w:tblBorders/*', $namespaces))
            Assert-True -Condition ($borders.Count -eq 6) -Message '布局表没有显式移除全部边框。'
            Assert-True -Condition (-not ($borders | Where-Object { $_.GetAttribute('val', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main') -ne 'nil' })) -Message '布局表仍含可见边框。'
            $cells = @($table.SelectNodes('./w:tr[1]/w:tc', $namespaces))
            foreach ($cell in $cells) {
                $cellWidth = [int]$cell.SelectSingleNode('./w:tcPr/w:tcW', $namespaces).GetAttribute('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
                foreach ($extent in @($cell.SelectNodes('.//wp:extent', $namespaces))) {
                    $imageWidthDxa = [int][Math]::Ceiling(([double]$extent.GetAttribute('cx')) / 635)
                    Assert-True -Condition ($imageWidthDxa -le $cellWidth) -Message '列内图片宽度超过单元格，渲染时会重叠。'
                }
            }
            if ($cells.Count -eq 3 -and -not ($cells | Where-Object { @($_.SelectNodes('.//w:drawing', $namespaces)).Count -ne 1 })) {
                Assert-True -Condition (-not ($cells | Where-Object { @($_.SelectNodes('.//w:tbl', $namespaces)).Count -ne 0 })) -Message '三图同行的图片仍套有 1×1 图形表。'
                $threeImagesFound = $true
            }
            if ($cells.Count -eq 2) {
                $firstHasImage = @($cells[0].SelectNodes('.//w:drawing', $namespaces)).Count -eq 1
                $firstHasNestedTable = @($cells[0].SelectNodes('.//w:tbl', $namespaces)).Count -gt 0
                $secondHasTable = @($cells[1].SelectNodes('.//w:tbl', $namespaces)).Count -ge 1
                $grid = @($table.SelectNodes('./w:tblGrid/w:gridCol', $namespaces) | ForEach-Object { [int]$_.GetAttribute('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main') })
                $ratio = if ($grid.Count -eq 2) { $grid[0] / ($grid[0] + $grid[1]) } else { 0 }
                if ($firstHasImage -and -not $firstHasNestedTable -and $secondHasTable -and [Math]::Abs($ratio - 0.4) -lt 0.01) { $mixedRowFound = $true }
            }
        }
        Assert-True -Condition $threeImagesFound -Message '没有找到三张图片同一行的 DOCX 结构。'
        Assert-True -Condition $mixedRowFound -Message '没有找到 40% / 60% 的图片与表格同排结构。'
        $pageSize = $layoutXml.SelectSingleNode('(//w:sectPr/w:pgSz)[last()]', $namespaces)
        Assert-True -Condition ($pageSize.GetAttribute('orient', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main') -eq 'landscape') -Message '复杂多栏文档没有使用横向页面避免内容挤压。'
    }
    finally {
        $layoutArchive.Dispose()
    }
    Remove-Item -LiteralPath $layoutOutput -Force
    Assert-True -Condition (-not (Test-Path -LiteralPath $layoutOutput)) -Message '布局验收 DOCX 未被永久删除。'

    $env:N2DD_FAKE_IMAGE_COUNT = '4'
    $env:N2DD_FAKE_TABLE_SEQUENCE = $layoutConversion.mappings.columns.tableSequence | ConvertTo-Json -Depth 5 -Compress
    $env:N2DD_FAKE_TABLE_BLOCK_PREFIX = 'fake-stage4-table'
    # 真实钉钉导入器可能把普通数据表降级为非表格块；分栏应依靠专用样式识别，不能依赖总表数相等。
    $env:N2DD_FAKE_OMIT_TABLE_INDEX = '3'
    # Word 导入遗留的 list.start=0 不符合钉钉 JSONML schema，分栏更新前必须最小化纠正为 1。
    $env:N2DD_FAKE_INVALID_LAYOUT_LIST_START_INDEX = '2'
    $layoutMigration = Invoke-JsonScript -Script $installedGui -Arguments @(
        '-Headless',
        '-InputPath', $layoutFixture,
        '-TargetType', 'folder',
        '-TargetId', 'fake-layout-folder',
        '-TargetDisplayName', '阶段 4 原生分栏验证',
        '-Profile', 'isolated-profile',
        '-DwsCommand', $fakeNpmDws,
        '-ForceMigration'
    )
    Assert-True -Condition ($layoutMigration.success -eq $true) -Message '阶段 4 原生分栏迁移没有成功。'
    Assert-True -Condition ($layoutMigration.nativeLayoutCount -eq 2) -Message '两个布局表没有全部恢复为钉钉原生分栏。'
    Assert-True -Condition ($layoutMigration.nativeLayoutsVerified -eq $true) -Message '钉钉原生分栏没有通过回读验证。'
    $layoutUpdateCalls = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object {
                $_.args[0] -eq 'doc' -and $_.args[1] -eq 'block' -and $_.args[2] -eq 'update' -and
                ([string]$_.args[([Array]::IndexOf([object[]]$_.args, '--block-id') + 1)]).StartsWith('fake-stage4-table-')
            }
    )
    Assert-True -Condition ($layoutUpdateCalls.Count -eq 2) -Message '只应更新两个布局表，普通数据表不得被修改。'
    Assert-True -Condition (-not ($layoutUpdateCalls | Where-Object { $_.args -contains 'fake-stage4-table-3' })) -Message '真实数据表被错误更新为分栏。'
    foreach ($call in $layoutUpdateCalls) {
        $elementIndex = [Array]::IndexOf([object[]]$call.args, '--element')
        $element = [string]$call.args[$elementIndex + 1] | ConvertFrom-Json
        Assert-True -Condition ($element[0] -eq 'table' -and $element[1].sr -eq $true) -Message '布局表没有设置钉钉原生分栏标记 sr=true。'
        Assert-True -Condition ($element[1].spacing -eq 12) -Message '原生分栏没有设置栏间距。'
        Assert-True -Condition ($null -eq $element[1].PSObject.Properties['bdr']) -Message '原生分栏仍带表格边框属性。'
        foreach ($cell in @($element[2] | Select-Object -Skip 2)) {
            Assert-True -Condition ($null -eq $cell[1].PSObject.Properties['bdr']) -Message '原生分栏单元格仍带边框属性。'
        }
        Assert-True -Condition (($element | ConvertTo-Json -Depth 30 -Compress) -notmatch '"start":0') -Message '原生分栏仍包含钉钉 JSONML 拒绝的 list.start=0。'
    }
    $secondLayoutCall = @($layoutUpdateCalls | Where-Object { $_.args -contains 'fake-stage4-table-2' })[0]
    $secondLayoutElementIndex = [Array]::IndexOf([object[]]$secondLayoutCall.args, '--element')
    $secondLayoutElement = [string]$secondLayoutCall.args[$secondLayoutElementIndex + 1] | ConvertFrom-Json
    Assert-True -Condition ($secondLayoutElement[2][2][2][1].list.start -eq 1) -Message 'Word 遗留的无效列表起始值没有被纠正为 1。'

    $env:N2DD_FAKE_SCENARIO = 'layout-update-unknown-once'
    $env:N2DD_FAKE_TABLE_BLOCK_PREFIX = 'fake-resume-layout'
    # 恢复用例故意不传 -ForceMigration；显式 force 的语义是允许再次导出。
    $layoutResumeArguments = @(
        '-Headless',
        '-InputPath', $layoutFixture,
        '-TargetType', 'folder',
        '-TargetId', 'fake-layout-resume-folder',
        '-TargetDisplayName', '阶段 4 分栏恢复验证',
        '-Profile', 'isolated-profile',
        '-DwsCommand', $fakeNpmDws
    )
    $layoutUnknown = Invoke-JsonScript -Script $installedGui -Arguments $layoutResumeArguments -ExpectedExitCode 1
    Assert-True -Condition ($layoutUnknown.success -eq $false) -Message '分栏首次更新未知时不应报告成功。'
    Assert-True -Condition ($layoutUnknown.message -match '不会重复导入') -Message '分栏更新未知时没有给出安全恢复说明。'
    $layoutImportCountBeforeResume = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.args[0] -eq 'doc' -and $_.args[1] -eq '+import' -and $_.args -contains 'fake-layout-resume-folder' }
    ).Count
    $layoutResumed = Invoke-JsonScript -Script $installedGui -Arguments $layoutResumeArguments
    Assert-True -Condition ($layoutResumed.success -eq $true) -Message '分栏未知状态没有从现有文档恢复成功。'
    Assert-True -Condition ($layoutResumed.resumedReadback -eq $true) -Message '分栏恢复没有标记为复用现有文档。'
    Assert-True -Condition ($layoutResumed.nativeLayoutCount -eq 2) -Message '恢复后原生分栏数量不一致。'
    $layoutImportCountAfterResume = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.args[0] -eq 'doc' -and $_.args[1] -eq '+import' -and $_.args -contains 'fake-layout-resume-folder' }
    ).Count
    Assert-True -Condition ($layoutImportCountAfterResume -eq $layoutImportCountBeforeResume) -Message '分栏恢复错误地重复导入了文档。'
    Remove-Item Env:N2DD_FAKE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_TABLE_SEQUENCE -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_TABLE_BLOCK_PREFIX -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_OMIT_TABLE_INDEX -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_INVALID_LAYOUT_LIST_START_INDEX -ErrorAction SilentlyContinue

    $subpageFixture = Join-Path $runRoot 'subpage-fixture'
    $rootPageName = '阶段 4 子页面目录 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $rootPageDirectory = Join-Path $subpageFixture $rootPageName
    $childPageName = '子页面 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $childPageDirectory = Join-Path $rootPageDirectory $childPageName
    [IO.Directory]::CreateDirectory($childPageDirectory) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $subpageFixture ($rootPageName + '.html')),
        '<!doctype html><html><head><meta charset="utf-8"><title>阶段 4 子页面目录</title></head><body><h1 class="page-title">阶段 4 子页面目录</h1><p><a href="阶段%204%20子页面目录%20aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/子页面%20bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.html">子页面入口</a></p></body></html>',
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $rootPageDirectory ($childPageName + '.html')),
        '<!doctype html><html><head><meta charset="utf-8"><title>子页面</title></head><body><h1 class="page-title">子页面</h1><p><a href="子页面%20bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/孙页面%20cccccccccccccccccccccccccccccccc.html">孙页面入口</a></p><p>CHILD-LINK-FINAL</p></body></html>',
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $childPageDirectory '孙页面 cccccccccccccccccccccccccccccccc.html'),
        '<!doctype html><html><head><meta charset="utf-8"><title>孙页面</title></head><body><h1 class="page-title">孙页面</h1><p>GRANDCHILD-LINK-FINAL</p></body></html>',
        [Text.UTF8Encoding]::new($false)
    )
    $subpageDefinitions = @(
        [ordered]@{ sourcePageIndex = 0; label = '子页面入口'; targetPageIndex = 1; targetTitle = '子页面' }
        [ordered]@{ sourcePageIndex = 1; label = '孙页面入口'; targetPageIndex = 2; targetTitle = '孙页面' }
    )
    $env:N2DD_FAKE_IMAGE_COUNT = '0'
    $env:N2DD_FAKE_SUBPAGE_LINKS = $subpageDefinitions | ConvertTo-Json -Depth 5 -Compress
    $env:N2DD_FAKE_SUBPAGE_BLOCK_PREFIX = 'fake-resume-subpage'
    $env:N2DD_FAKE_SCENARIO = 'subpage-update-unknown-once'
    # 默认执行才会安全恢复已有文档；force 应重新创建文档。
    $subpageArguments = @(
        '-Headless',
        '-InputPath', $subpageFixture,
        '-TargetType', 'folder',
        '-TargetId', 'fake-subpage-resume-folder',
        '-TargetDisplayName', '阶段 4 子页面目录恢复验证',
        '-Profile', 'isolated-profile',
        '-DwsCommand', $fakeNpmDws
    )
    $subpageUnknown = Invoke-JsonScript -Script $installedGui -Arguments $subpageArguments -ExpectedExitCode 1
    Assert-True -Condition ($subpageUnknown.success -eq $false) -Message '子页面目录首次更新未知时不应报告成功。'
    Assert-True -Condition ($subpageUnknown.message -match '不会重复导入') -Message '子页面目录更新未知时没有给出安全恢复说明。'
    $subpageImportCountBeforeResume = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.args[0] -eq 'doc' -and $_.args[1] -eq '+import' -and $_.args -contains 'fake-subpage-resume-folder' }
    ).Count
    $subpageResumed = Invoke-JsonScript -Script $installedGui -Arguments $subpageArguments
    Assert-True -Condition ($subpageResumed.success -eq $true) -Message '子页面目录未知状态没有从现有文档恢复成功。'
    Assert-True -Condition ($subpageResumed.resumedReadback -eq $true) -Message '子页面目录恢复没有标记为复用现有文档。'
    Assert-True -Condition ($subpageResumed.nativeSubpageTocItemCount -eq 2) -Message '原生目录没有包含两个子页面标题。'
    Assert-True -Condition ($subpageResumed.nativeSubpageTocVerified -eq $true) -Message '钉钉原生子页面目录没有通过回读。'
    $subpageImportCountAfterResume = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.args[0] -eq 'doc' -and $_.args[1] -eq '+import' -and $_.args -contains 'fake-subpage-resume-folder' }
    ).Count
    Assert-True -Condition ($subpageImportCountAfterResume -eq $subpageImportCountBeforeResume) -Message '子页面目录恢复错误地重复导入了文档。'
    Remove-Item Env:N2DD_FAKE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_SUBPAGE_LINKS -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_SUBPAGE_BLOCK_PREFIX -ErrorAction SilentlyContinue

    $fakeDwsCommandDirectory = Join-Path $runRoot 'bin'
    [IO.Directory]::CreateDirectory($fakeDwsCommandDirectory) | Out-Null
    $fakeDwsLauncher = Join-Path $fakeDwsCommandDirectory 'fake-dws.cmd'
    [IO.File]::WriteAllText(
        $fakeDwsLauncher,
        "@echo off`r`n`"$nodePath`" `"$runtimeFakeDws`" %*`r`n",
        [Text.ASCIIEncoding]::new()
    )
    $env:PATH = $fakeDwsCommandDirectory + [IO.Path]::PathSeparator + $originalPath
    $folderProbe = Invoke-JsonScript -Script $installedGui -Arguments @(
        '-FolderBrowserProbe',
        '-Profile', 'isolated-profile',
        '-FolderSearchQuery', 'Notion2DingDing 验证输出',
        '-DwsCommand', $runtimeFakeDws
    )
    Assert-True -Condition (@($folderProbe.roots).Count -eq 2) -Message '文件夹选择器没有同时加载“我的文件”和企业文档空间。'
    Assert-True -Condition (@($folderProbe.firstRootChildren).Count -eq 2) -Message '文件夹选择器没有加载或分页合并全部子文件夹。'
    Assert-True -Condition (-not (@($folderProbe.firstRootChildren).Name -contains '普通文件.txt')) -Message '文件夹选择器错误显示了普通文件。'
    Assert-True -Condition (@($folderProbe.searchResults).Count -eq 2) -Message '文件夹选择器没有分页合并全局搜索结果。'
    Assert-True -Condition (@($folderProbe.searchResults).Name -contains 'Notion2DingDing 验证输出') -Message '文件夹选择器无法搜索目录树之外的验证输出文件夹。'
    Assert-True -Condition (-not (@($folderProbe.searchResults).Name -contains 'Notion2DingDing 验证输出说明.txt')) -Message '文件夹搜索错误显示了普通文件。'

    $todoFixture = Join-Path $runRoot 'todo-fixture'
    [IO.Directory]::CreateDirectory($todoFixture) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $todoFixture '阶段 4 待办验证 dddddddddddddddddddddddddddddddd.html'),
        '<!doctype html><html><head><meta charset="utf-8"><title>阶段 4 待办验证</title></head><body><h1 class="page-title">阶段 4 待办验证</h1><ul class="to-do-list"><li><input type="checkbox" class="checkbox checkbox-on" disabled="" checked=""/> <span class="to-do-children-checked">已完成事项</span></li></ul><ul class="to-do-list"><li><input type="checkbox" class="checkbox checkbox-off" disabled=""/> <span class="to-do-children-unchecked">未完成事项</span></li></ul><p>TODO-FINAL</p></body></html>',
        [Text.UTF8Encoding]::new($false)
    )
    $todoOutput = Join-Path $runRoot 'todo-stage4.docx'
    $todoConversionJson = & $installedConverter `
        -InputPath $todoFixture `
        -OutputPath $todoOutput `
        -ExpectedImageCount 0 `
        -RequiredText @('TODO-FINAL')
    $todoConversion = $todoConversionJson | ConvertFrom-Json
    Assert-True -Condition ($todoConversion.mappings.todo.detectedCount -eq 2) -Message 'Notion HTML 待办数量没有被转换器识别。'
    Assert-True -Condition ($todoConversion.mappings.todo.checkedCount -eq 1) -Message '已完成待办状态没有保留。'
    Assert-True -Condition ($todoConversion.mappings.todo.uncheckedCount -eq 1) -Message '未完成待办状态没有保留。'
    Assert-True -Condition ($todoConversion.mappings.todo.ordinaryListCount -eq 0) -Message '待办仍被编码为普通圆点列表。'
    $todoArchive = [IO.Compression.ZipFile]::OpenRead($todoOutput)
    try {
        $todoDocumentEntry = $todoArchive.GetEntry('word/document.xml')
        $todoReader = [IO.StreamReader]::new($todoDocumentEntry.Open(), [Text.Encoding]::UTF8, $true)
        try { [xml]$todoXml = $todoReader.ReadToEnd() } finally { $todoReader.Dispose() }
        $todoNamespaces = [Xml.XmlNamespaceManager]::new($todoXml.NameTable)
        $todoNamespaces.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        $todoParagraphs = @($todoXml.SelectNodes('//w:p', $todoNamespaces) | Where-Object {
            ((@($_.SelectNodes('.//w:t', $todoNamespaces)) | ForEach-Object { $_.InnerText }) -join '') -match '^[☐☒]'
        })
        Assert-True -Condition ($todoParagraphs.Count -eq 2) -Message 'DOCX 没有保留两条待办方框。'
        Assert-True -Condition (-not ($todoParagraphs | Where-Object { $_.SelectSingleNode('./w:pPr/w:numPr', $todoNamespaces) })) -Message 'DOCX 待办仍带普通项目符号编号。'
    }
    finally {
        $todoArchive.Dispose()
    }
    Remove-Item -LiteralPath $todoOutput -Force
    Assert-True -Condition (-not (Test-Path -LiteralPath $todoOutput)) -Message '待办验收 DOCX 未被永久删除。'

    $env:N2DD_FAKE_IMAGE_COUNT = '0'
    $env:N2DD_FAKE_TODO_STATES = 'checked,unchecked'
    $todoMigration = Invoke-JsonScript -Script $installedGui -Arguments @(
        '-Headless',
        '-InputPath', $todoFixture,
        '-TargetType', 'folder',
        '-TargetId', 'fake-orphan-folder',
        '-TargetDisplayName', 'Notion2DingDing 验证输出',
        '-Profile', 'isolated-profile',
        '-DwsCommand', $fakeNpmDws,
        '-ForceMigration'
    )
    Assert-True -Condition ($todoMigration.success -eq $true) -Message '阶段 4 待办迁移没有成功。'
    Assert-True -Condition ($todoMigration.nativeTodoCount -eq 2) -Message '两条待办没有全部恢复为钉钉原生块。'
    Assert-True -Condition ($todoMigration.nativeTodoVerified -eq $true) -Message '钉钉原生待办没有通过回读验证。'
    $todoUpdateCalls = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object {
                $_.args[0] -eq 'doc' -and $_.args[1] -eq 'block' -and $_.args[2] -eq 'update' -and
                ([string]$_.args[([Array]::IndexOf([object[]]$_.args, '--block-id') + 1)]).StartsWith('fake-todo-')
            }
    )
    Assert-True -Condition ($todoUpdateCalls.Count -eq 2) -Message 'DWS 没有收到两次原生待办块更新。'
    $nativeStates = @()
    foreach ($call in $todoUpdateCalls) {
        $elementIndex = [Array]::IndexOf([object[]]$call.args, '--element')
        $element = [string]$call.args[$elementIndex + 1] | ConvertFrom-Json
        Assert-True -Condition ($element[1].list.isTaskList -eq $true) -Message '待办块更新没有设置 isTaskList=true。'
        $nativeStates += [bool]$element[1].list.isChecked
        Assert-True -Condition (($element | ConvertTo-Json -Depth 20) -notmatch '[☐☒]') -Message '恢复原生待办后仍残留静态方框字符。'
    }
    Assert-True -Condition (($nativeStates -join ',') -eq 'True,False') -Message '原生待办的已完成/未完成状态顺序不一致。'
    Remove-Item Env:N2DD_FAKE_TODO_STATES -ErrorAction SilentlyContinue

    $env:N2DD_FAKE_SCENARIO = 'todo-update-unknown-once'
    $env:N2DD_FAKE_TODO_STATES = 'checked,unchecked'
    $env:N2DD_FAKE_TODO_BLOCK_PREFIX = 'fake-resume-todo'
    # 默认执行才会安全恢复已有文档；force 应重新创建文档。
    $resumeArguments = @(
        '-Headless',
        '-InputPath', $todoFixture,
        '-TargetType', 'folder',
        '-TargetId', 'fake-resume-folder',
        '-TargetDisplayName', '阶段 4 待办恢复验证',
        '-Profile', 'isolated-profile',
        '-DwsCommand', $fakeNpmDws
    )
    $todoUnknown = Invoke-JsonScript -Script $installedGui -Arguments $resumeArguments -ExpectedExitCode 1
    Assert-True -Condition ($todoUnknown.success -eq $false) -Message '待办首次写入未知时不应报告成功。'
    Assert-True -Condition ($todoUnknown.message -match '不会重复导入') -Message '待办首次写入未知时没有给出安全恢复说明。'
    $importCountBeforeResume = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.args[0] -eq 'doc' -and $_.args[1] -eq '+import' -and $_.name -eq '阶段 4 待办验证' }
    ).Count
    $todoResumed = Invoke-JsonScript -Script $installedGui -Arguments $resumeArguments
    Assert-True -Condition ($todoResumed.success -eq $true) -Message '待办未知状态没有从现有文档恢复成功。'
    Assert-True -Condition ($todoResumed.resumedReadback -eq $true) -Message '待办恢复没有标记为复用现有文档。'
    Assert-True -Condition ($todoResumed.nativeTodoCount -eq 2) -Message '恢复后原生待办数量不一致。'
    $importCountAfterResume = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.args[0] -eq 'doc' -and $_.args[1] -eq '+import' -and $_.name -eq '阶段 4 待办验证' }
    ).Count
    Assert-True -Condition ($importCountAfterResume -eq $importCountBeforeResume) -Message '待办恢复错误地重复导入了文档。'
    Remove-Item Env:N2DD_FAKE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_TODO_STATES -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_TODO_BLOCK_PREFIX -ErrorAction SilentlyContinue

    $codeFixture = Join-Path $runRoot 'code-fixture'
    [IO.Directory]::CreateDirectory($codeFixture) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $codeFixture '阶段 4 代码块验证 eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.html'),
        @'
<!doctype html><html><head><meta charset="utf-8"><title>阶段 4 代码块验证</title></head><body>
<h1 class="page-title">阶段 4 代码块验证</h1>
<pre class="code" data-language="JavaScript"><code>const dns = &quot;223.5.5.5&quot;;</code></pre>
<pre class="sourceCode shell"><code class="sourceCode shell">sudo nmcli connection modify enP1s2f0 \
    ipv4.ignore-auto-dns yes \
    ipv4.dns &quot;223.5.5.5,119.29.29.29&quot;</code></pre>
<pre class="code" data-language="bash"><code>getent ahostsv4 baidu.com
ping -4 -c 3 baidu.com</code></pre>
<p>CODE-FINAL</p></body></html>
'@,
        [Text.UTF8Encoding]::new($false)
    )
    $codeOutput = Join-Path $runRoot 'code-stage4.docx'
    $codeConversionJson = & $installedConverter `
        -InputPath $codeFixture `
        -OutputPath $codeOutput `
        -ExpectedImageCount 0 `
        -RequiredText @('CODE-FINAL')
    $codeConversion = $codeConversionJson | ConvertFrom-Json
    Assert-True -Condition ($codeConversion.mappings.code.detectedCount -eq 3) -Message 'Notion HTML 代码块数量没有被转换器识别。'
    Assert-True -Condition ($codeConversion.mappings.documentTitle.duplicateTitleBlockCount -eq 0) -Message '根页面标题仍被重复写入 DOCX 正文。'
    Assert-True -Condition ($codeConversion.mappings.code.docxSourceCodeCount -eq 3) -Message 'DOCX SourceCode 段落数量不一致。'
    Assert-True -Condition (($codeConversion.mappings.code.blocks.syntax -join ',') -eq 'javascript,shell,bash') -Message '代码块语言没有按 HTML 顺序保留。'
    Assert-True -Condition ($codeConversion.mappings.code.blocks[1].code -match "nmcli connection modify[\s\S]+ipv4\.dns") -Message '多行代码块正文或换行没有保留。'
    Remove-Item -LiteralPath $codeOutput -Force
    Assert-True -Condition (-not (Test-Path -LiteralPath $codeOutput)) -Message '代码块验收 DOCX 未被永久删除。'

    $codeDefinitions = @(
        [ordered]@{ syntax = 'javascript'; code = 'const dns = "223.5.5.5";' }
        [ordered]@{ syntax = 'shell'; code = "sudo nmcli connection modify enP1s2f0 \`n    ipv4.ignore-auto-dns yes \`n    ipv4.dns `"223.5.5.5,119.29.29.29`"" }
        [ordered]@{ syntax = 'bash'; code = "getent ahostsv4 baidu.com`nping -4 -c 3 baidu.com" }
    )
    $env:N2DD_FAKE_IMAGE_COUNT = '0'
    $env:N2DD_FAKE_CODE_BLOCKS = $codeDefinitions | ConvertTo-Json -Depth 5 -Compress
    $env:N2DD_FAKE_CODE_BLOCK_PREFIX = 'fake-stage4-code'
    $codeMigration = Invoke-JsonScript -Script $installedGui -Arguments @(
        '-Headless',
        '-InputPath', $codeFixture,
        '-TargetType', 'folder',
        '-TargetId', 'fake-code-folder',
        '-TargetDisplayName', '阶段 4 代码块验证',
        '-Profile', 'isolated-profile',
        '-DwsCommand', $fakeNpmDws,
        '-ForceMigration'
    )
    Assert-True -Condition ($codeMigration.success -eq $true) -Message '阶段 4 代码块迁移没有成功。'
    Assert-True -Condition ($codeMigration.nativeCodeBlockCount -eq 3) -Message '三个代码块没有全部恢复为钉钉原生块。'
    Assert-True -Condition ($codeMigration.nativeCodeBlocksVerified -eq $true) -Message '钉钉原生代码块没有通过回读验证。'
    $codeUpdateCalls = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object {
                $_.args[0] -eq 'doc' -and $_.args[1] -eq 'block' -and $_.args[2] -eq 'update' -and
                ([string]$_.args[([Array]::IndexOf([object[]]$_.args, '--block-id') + 1)]).StartsWith('fake-stage4-code-')
            }
    )
    Assert-True -Condition ($codeUpdateCalls.Count -eq 3) -Message 'DWS 没有收到三次原生代码块更新。'
    foreach ($call in $codeUpdateCalls) {
        $elementIndex = [Array]::IndexOf([object[]]$call.args, '--element')
        $element = [string]$call.args[$elementIndex + 1] | ConvertFrom-Json
        Assert-True -Condition ($element[0] -eq 'code') -Message '代码段落没有更新为钉钉原生 code 块。'
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$element[1].code)) -Message '原生代码块缺少代码正文。'
    }

    $env:N2DD_FAKE_SCENARIO = 'code-update-unknown-once'
    $env:N2DD_FAKE_CODE_BLOCK_PREFIX = 'fake-resume-code'
    # 默认执行才会安全恢复已有文档；force 应重新创建文档。
    $codeResumeArguments = @(
        '-Headless',
        '-InputPath', $codeFixture,
        '-TargetType', 'folder',
        '-TargetId', 'fake-code-resume-folder',
        '-TargetDisplayName', '阶段 4 代码块恢复验证',
        '-Profile', 'isolated-profile',
        '-DwsCommand', $fakeNpmDws
    )
    $codeUnknown = Invoke-JsonScript -Script $installedGui -Arguments $codeResumeArguments -ExpectedExitCode 1
    Assert-True -Condition ($codeUnknown.success -eq $false) -Message '代码块首次写入未知时不应报告成功。'
    Assert-True -Condition ($codeUnknown.message -match '不会重复导入') -Message '代码块首次写入未知时没有给出安全恢复说明。'
    $codeImportCountBeforeResume = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.args[0] -eq 'doc' -and $_.args[1] -eq '+import' -and $_.name -eq '阶段 4 代码块验证' }
    ).Count
    $codeResumed = Invoke-JsonScript -Script $installedGui -Arguments $codeResumeArguments
    Assert-True -Condition ($codeResumed.success -eq $true) -Message '代码块未知状态没有从现有文档恢复成功。'
    Assert-True -Condition ($codeResumed.resumedReadback -eq $true) -Message '代码块恢复没有标记为复用现有文档。'
    Assert-True -Condition ($codeResumed.nativeCodeBlockCount -eq 3) -Message '恢复后原生代码块数量不一致。'
    $codeImportCountAfterResume = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.args[0] -eq 'doc' -and $_.args[1] -eq '+import' -and $_.name -eq '阶段 4 代码块验证' }
    ).Count
    Assert-True -Condition ($codeImportCountAfterResume -eq $codeImportCountBeforeResume) -Message '代码块恢复错误地重复导入了文档。'
    Remove-Item Env:N2DD_FAKE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_CODE_BLOCKS -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_CODE_BLOCK_PREFIX -ErrorAction SilentlyContinue

    $env:N2DD_FAKE_IMAGE_COUNT = '2'
    $migrationInnerZip = Join-Path $runRoot 'fixture-Part-1.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($fixture, $migrationInnerZip)
    $migrationWrapper = Join-Path $runRoot 'migration-wrapper'
    [IO.Directory]::CreateDirectory($migrationWrapper) | Out-Null
    Copy-Item -LiteralPath $migrationInnerZip -Destination $migrationWrapper
    $migrationOuterZip = Join-Path $runRoot 'random-download-name.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($migrationWrapper, $migrationOuterZip)
    $migration = Invoke-JsonScript -Script $installedGui -Arguments @(
        '-Headless',
        '-InputPath', $migrationOuterZip,
        '-TargetType', 'folder',
        '-TargetId', 'fake-stage4-folder',
        '-TargetDisplayName', '我的文件 / 阶段 4 测试',
        '-Profile', 'isolated-profile',
        '-DwsCommand', $runtimeFakeDws,
        '-ForceMigration'
    )
    Assert-True -Condition ($migration.success -eq $true) -Message '安装后的一键界面未能完成代表性迁移。'
    Assert-True -Condition ($migration.documentUrl -eq 'https://alidocs.dingtalk.com/i/nodes/fake-stage2-node') -Message '一键界面迁移未返回预期文档 URL。'
    Assert-True -Condition ($migration.title -eq '阶段 1 验证页面') -Message '一键界面迁移没有自动使用 Notion 根页面标题。'
    Assert-True -Condition ($migration.requestedTitle -eq '阶段 1 验证页面') -Message '一键界面没有保留自动识别的原始标题。'
    Assert-True -Condition ($migration.titleAdjusted -eq $false) -Message '没有同名冲突时不应报告标题被钉钉调整。'
    Assert-True -Condition ($migration.resumedReadback -eq $false) -Message '首次迁移不应报告为恢复回读。'
    Assert-True -Condition ($migration.cleanupVerified -eq $true) -Message '一键界面未确认永久删除 DOCX。'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $installDirectory 'runtime\.n2dd-tmp'))) -Message '安装后的迁移残留临时任务目录。'

    $configured = Invoke-LauncherJson -Arguments @('config', '--show')
    Assert-True -Condition ($configured.folder -eq 'fake-stage4-folder') -Message '一键界面没有保存默认文件夹。'
    Assert-True -Condition ($configured.folderName -eq '我的文件 / 阶段 4 测试') -Message '一键界面没有保存文件夹显示路径。'
    Assert-True -Condition ($configured.profile -eq 'isolated-profile') -Message '一键界面没有保存 dws profile。'

    $calls = @(
        Get-Content -LiteralPath $dwsLog -Encoding UTF8 |
            Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json }
    )
    $importCall = @($calls | Where-Object { $_.args -contains '+import' })[-1]
    Assert-True -Condition ($importCall.args -contains 'fake-stage4-folder') -Message '迁移未使用保存的默认文件夹。'
    Assert-True -Condition ($importCall.args -contains 'isolated-profile') -Message '迁移未使用保存的 dws profile。'

    [IO.File]::WriteAllText((Join-Path $installDirectory 'stale-owned-file.tmp'), '旧版本残留')
    $upgrade = Invoke-JsonScript -Script $installer -Arguments @(
        '-Action', 'Upgrade',
        '-InstallDirectory', $installDirectory,
        '-DataDirectory', $dataDirectory,
        '-LauncherDirectory', $launcherDirectory,
        '-StartMenuDirectory', $startMenuDirectory,
        '-SkipDependencyCheck'
    )
    Assert-True -Condition ($upgrade.success -eq $true) -Message '升级必须成功。'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $installDirectory 'stale-owned-file.tmp'))) -Message '升级没有替换旧程序目录。'
    $configAfterUpgrade = Invoke-LauncherJson -Arguments @('config', '--show')
    Assert-True -Condition ($configAfterUpgrade.folder -eq 'fake-stage4-folder') -Message '升级后默认目标配置丢失。'
    Assert-True -Condition ($configAfterUpgrade.folderName -eq '我的文件 / 阶段 4 测试') -Message '升级后文件夹显示路径丢失。'
    Assert-True -Condition (Test-Path -LiteralPath $shortcutPath) -Message '升级后一键使用快捷方式丢失。'

    $uninstall = Invoke-JsonScript -Script $installer -Arguments @(
        '-Action', 'Uninstall',
        '-InstallDirectory', $installDirectory,
        '-DataDirectory', $dataDirectory,
        '-LauncherDirectory', $launcherDirectory,
        '-StartMenuDirectory', $startMenuDirectory
    )
    Assert-True -Condition ($uninstall.success -eq $true) -Message '卸载必须成功。'
    Assert-True -Condition (-not (Test-Path -LiteralPath $installDirectory)) -Message '卸载后程序目录仍存在。'
    Assert-True -Condition (-not (Test-Path -LiteralPath $dataDirectory)) -Message '卸载后数据目录仍存在。'
    Assert-True -Condition (-not (Test-Path -LiteralPath $launcherPath)) -Message '卸载后启动器仍存在。'
    Assert-True -Condition (-not (Test-Path -LiteralPath $shortcutDirectory)) -Message '卸载后一键使用快捷方式目录仍存在。'
    Assert-True -Condition (Test-Path -LiteralPath $foreignPath) -Message '卸载误删了项目范围外文件。'

    [IO.Directory]::CreateDirectory($launcherDirectory) | Out-Null
    [IO.File]::WriteAllText($launcherPath, '@echo off', [Text.ASCIIEncoding]::new())
    $refused = Invoke-JsonScript -Script $installer -Arguments @(
        '-Action', 'Uninstall',
        '-InstallDirectory', $installDirectory,
        '-DataDirectory', $dataDirectory,
        '-LauncherDirectory', $launcherDirectory,
        '-StartMenuDirectory', $startMenuDirectory
    ) -ExpectedExitCode 1
    Assert-True -Condition ($refused.success -eq $false) -Message '卸载遇到非本项目启动器时必须失败。'
    Assert-True -Condition (Test-Path -LiteralPath $launcherPath) -Message '卸载误删了非本项目启动器。'

    $fixtureHashAfter = Get-FileSha256 -Path $fixtureFile
    Assert-True -Condition ($fixtureHashAfter -eq $fixtureHashBefore) -Message '安装、迁移或卸载修改了用户源输入。'

    [ordered]@{
        success = $true
        install = $true
        doctorMissingGuidance = $true
        doctorReady = $true
        oneClickUi = $true
        folderPicker = $true
        titleInference = $true
        htmlOnly = $true
        imageOptimization = $true
        singleImageWithoutTable = $true
        htmlLayoutFidelity = $true
        nativeColumns = $true
        nativeSubpageToc = $true
        nativeTodo = $true
        nativeCodeBlocks = $true
        configureInUi = $true
        migrateFromUi = $true
        upgrade = $true
        uninstall = $true
        foreignFilesPreserved = $true
        sourceInputPreserved = $true
    } | ConvertTo-Json
}
finally {
    $env:PATH = $originalPath
    Remove-Item Env:N2DD_FAKE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_IMAGE_COUNT -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_TODO_STATES -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_TODO_BLOCK_PREFIX -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_TABLE_SEQUENCE -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_TABLE_BLOCK_PREFIX -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_OMIT_TABLE_INDEX -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_INVALID_LAYOUT_LIST_START_INDEX -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_SUBPAGE_LINKS -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_SUBPAGE_BLOCK_PREFIX -ErrorAction SilentlyContinue
    $resolvedRunRoot = [IO.Path]::GetFullPath($runRoot).TrimEnd('\')
    if (
        $resolvedRunRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRunRoot).StartsWith('notion2dingding-stage4-', [StringComparison]::Ordinal)
    ) {
        Remove-Item -LiteralPath $resolvedRunRoot -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $resolvedRunRoot) {
            throw "阶段 4 隔离环境未能永久删除：$resolvedRunRoot"
        }
    }
    else {
        throw "拒绝清理未通过边界校验的阶段 4 路径：$resolvedRunRoot"
    }
}
