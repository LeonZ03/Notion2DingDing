[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path $env:TEMP ("notion2dingding-stage7-test-" + [Guid]::NewGuid().ToString('N'))
$publishedExtensionId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $algorithm.Dispose() }
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $outputRoot = Join-Path $testRoot 'release'
    & $powershellPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repositoryRoot 'scripts\build-release.ps1') `
        -OutputDirectory $outputRoot `
        -PublishedExtensionId $publishedExtensionId
    if ($LASTEXITCODE -ne 0) { throw "发布包构建失败：exit=$LASTEXITCODE" }

    $releaseDirectory = Join-Path $outputRoot 'v0.1.0'
    $releaseManifestPath = Join-Path $releaseDirectory 'release-manifest.json'
    Assert-True -Condition (Test-Path -LiteralPath $releaseManifestPath -PathType Leaf) -Message '缺少 release-manifest.json。'
    $releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($releaseManifest.edgeSubmissionReady -eq $true) -Message '提供正式扩展 ID 后仍未标记 Edge 提交就绪。'
    Assert-True -Condition ($releaseManifest.publishedExtensionId -eq $publishedExtensionId) -Message '正式扩展 ID 未写入发布清单。'
    Assert-True -Condition ($releaseManifest.codeSigned -eq $false) -Message '未签名候选包不得误报已签名。'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extensionZip = Join-Path $releaseDirectory 'Notion2DingDing-Edge-v0.1.0.zip'
    $archive = [IO.Compression.ZipFile]::OpenRead($extensionZip)
    try {
        $entries = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        Assert-True -Condition ($entries -contains 'manifest.json') -Message 'Edge ZIP 根目录缺少 manifest.json。'
        Assert-True -Condition ($entries -contains 'compatibility.js') -Message 'Edge ZIP 缺少兼容检查代码。'
        Assert-True -Condition ($entries -contains '_locales/zh_CN/messages.json') -Message 'Edge ZIP 缺少简体中文本地化消息。'
        Assert-True -Condition (-not ($entries -contains 'icons/icon-master-v2.png')) -Message 'Edge ZIP 不得包含图标生成主图。'
        Assert-True -Condition (@($entries | Where-Object { $_ -match '(?i)(\.env|token|cookie|artifact|fixture)' }).Count -eq 0) -Message 'Edge ZIP 包含不应发布的敏感或测试文件。'

        $manifestEntry = $archive.GetEntry('manifest.json')
        $manifestReader = [IO.StreamReader]::new($manifestEntry.Open(), [Text.Encoding]::UTF8)
        try { $storeManifest = $manifestReader.ReadToEnd() | ConvertFrom-Json }
        finally { $manifestReader.Dispose() }
        Assert-True -Condition (-not $storeManifest.PSObject.Properties['key']) -Message 'Edge 商店 ZIP 的 manifest 不得包含 key 字段。'
        Assert-True -Condition ($storeManifest.default_locale -eq 'zh_CN') -Message 'Edge 商店 ZIP 默认语言必须是简体中文。'
    }
    finally {
        $archive.Dispose()
    }

    $developmentManifest = Get-Content -LiteralPath (Join-Path $repositoryRoot 'dist\edge-extension\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($null -ne $developmentManifest.PSObject.Properties['key']) -Message '开发版扩展必须保留 key，以维持固定 Native Messaging 扩展 ID。'

    foreach ($artifact in $releaseManifest.artifacts) {
        $artifactPath = Join-Path $releaseDirectory ([string]$artifact.name)
        Assert-True -Condition (Test-Path -LiteralPath $artifactPath -PathType Leaf) -Message "缺少发布产物：$($artifact.name)"
        Assert-True -Condition ((Get-Sha256 -Path $artifactPath) -eq [string]$artifact.sha256) -Message "SHA-256 不匹配：$($artifact.name)"
    }
    foreach ($document in @('PRIVACY.md', 'THIRD_PARTY_NOTICES.md', '安装与升级说明.md', 'checksums.sha256')) {
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $releaseDirectory $document) -PathType Leaf) -Message "发布目录缺少：$document"
    }
    $installationGuide = Get-Content -LiteralPath (Join-Path $releaseDirectory '安装与升级说明.md') -Raw -Encoding UTF8
    Assert-True -Condition ($installationGuide.Contains('更多信息')) -Message '未签名 v0.1.0 缺少 SmartScreen 操作说明。'
    Assert-True -Condition ($installationGuide.Contains('checksums.sha256')) -Message '未签名安装说明缺少 SHA-256 核对入口。'
    $popupMarkup = Get-Content -LiteralPath (Join-Path $repositoryRoot 'dist\edge-extension\popup.html') -Raw -Encoding UTF8
    Assert-True -Condition ($popupMarkup.Contains('v0.1.0 安装包暂未签名')) -Message '扩展安装引导未提示 v0.1.0 安装包未签名。'

    $installRoot = Join-Path $testRoot 'installed'
    $local = Join-Path $installRoot 'Programs\Core'
    $data = Join-Path $installRoot 'Data'
    $launcher = Join-Path $installRoot 'Launcher'
    $startMenu = Join-Path $installRoot 'StartMenu'
    $native = Join-Path $installRoot 'Programs\Host'
    $setup = Join-Path $releaseDirectory 'Notion2DingDing-Setup.exe'
    & $setup --no-pause `
        -SkipDependencyInstall -SkipDependencyCheck -SkipRegistry -Quiet `
        -LocalInstallDirectory $local -DataDirectory $data -LauncherDirectory $launcher `
        -StartMenuDirectory $startMenu -NativeInstallDirectory $native
    if ($LASTEXITCODE -ne 0) { throw "隔离安装失败：exit=$LASTEXITCODE" }

    $nativeManifestPath = Join-Path $native 'com.leonz03.notion2dingding.json'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $local '.n2dd-install.json')) -Message '隔离安装缺少本地核心标记。'
    Assert-True -Condition (Test-Path -LiteralPath $nativeManifestPath) -Message '隔离安装缺少 Native Host 清单。'
    $nativeManifest = Get-Content -LiteralPath $nativeManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($nativeManifest.allowed_origins -contains 'chrome-extension://hheldkapioofhdbblmgfokdnpgfgaafo/') -Message 'Native Host 未保留开发/固定扩展 ID。'
    Assert-True -Condition ($nativeManifest.allowed_origins -contains "chrome-extension://$publishedExtensionId/") -Message 'Native Host 未加入 Edge Add-ons 正式扩展 ID。'

    & $setup --no-pause -Action Uninstall `
        -SkipDependencyInstall -SkipDependencyCheck -SkipRegistry -Quiet `
        -LocalInstallDirectory $local -DataDirectory $data -LauncherDirectory $launcher `
        -StartMenuDirectory $startMenu -NativeInstallDirectory $native
    if ($LASTEXITCODE -ne 0) { throw "隔离卸载失败：exit=$LASTEXITCODE" }
    Assert-True -Condition (-not (Test-Path -LiteralPath $local)) -Message '隔离卸载后本地核心仍存在。'
    Assert-True -Condition (-not (Test-Path -LiteralPath $native)) -Message '隔离卸载后 Native Host 仍存在。'
    Assert-True -Condition (-not (Test-Path -LiteralPath $data)) -Message '隔离卸载后数据目录仍存在。'

    [ordered]@{
        success = $true
        edgePackage = $true
        installerRoundTrip = $true
        publishedExtensionId = $true
        checksums = $true
        privacyAndNotices = $true
        unsignedInstallerDisclosure = $true
        cleanupVerified = $true
    } | ConvertTo-Json -Depth 4
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
