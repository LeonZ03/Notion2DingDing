[CmdletBinding()]
param(
    [string]$OutputDirectory,

    [ValidatePattern('^$|^[a-p]{32}$')]
    [string]$PublishedExtensionId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$packagePath = Join-Path $repositoryRoot 'package.json'
$extensionManifestPath = Join-Path $repositoryRoot 'apps\edge-extension\manifest.json'
$storeIdentityPath = Join-Path $repositoryRoot 'apps\edge-extension\store-identity.json'
$package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 | ConvertFrom-Json
$extensionManifest = Get-Content -LiteralPath $extensionManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$storeIdentity = $null
if (Test-Path -LiteralPath $storeIdentityPath -PathType Leaf) {
    $storeIdentity = Get-Content -LiteralPath $storeIdentityPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($PublishedExtensionId)) {
        $PublishedExtensionId = [string]$storeIdentity.crxId
    }
}
if ($PublishedExtensionId -and $PublishedExtensionId -notmatch '^[a-p]{32}$') {
    throw 'Edge Add-ons CRX ID 必须是 32 个 a-p 小写字母。'
}
$version = [string]$package.version
if ([string]::IsNullOrWhiteSpace($version) -or $version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'package.json version 必须是三段数字版本。'
}
if ([string]$extensionManifest.version -ne $version) {
    throw "扩展版本 $($extensionManifest.version) 与项目版本 $version 不一致。"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'dist\release'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
$releaseDirectory = Join-Path $OutputDirectory "v$version"
$root = [IO.Path]::GetPathRoot($releaseDirectory).TrimEnd('\')
if ($releaseDirectory.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $releaseDirectory.Length -le ($root.Length + 8)) {
    throw "发布目录过于宽泛，拒绝操作：$releaseDirectory"
}

function Get-ExtensionIdFromKey {
    param([Parameter(Mandatory)][string]$Key)
    $keyBytes = [Convert]::FromBase64String($Key)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($keyBytes) } finally { $sha.Dispose() }
    $alphabet = 'abcdefghijklmnop'
    $builder = [Text.StringBuilder]::new(32)
    foreach ($value in $hash[0..15]) {
        [void]$builder.Append($alphabet[[int]($value -shr 4)])
        [void]$builder.Append($alphabet[[int]($value -band 15)])
    }
    return $builder.ToString()
}

function Copy-ReleaseFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "发布源文件不存在：$Source"
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Destination)) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Failure
    )
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Failure（exit=$LASTEXITCODE）" }
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

$npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue)
if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
if (-not $npm) { throw '缺少 npm，无法构建发布包。' }
$go = Get-Command go.exe -ErrorAction SilentlyContinue
if (-not $go) { $go = Get-Command go -ErrorAction SilentlyContinue }
if (-not $go) {
    $userGo = Join-Path $env:LOCALAPPDATA 'Programs\Go\bin\go.exe'
    if (Test-Path -LiteralPath $userGo -PathType Leaf) { $go = Get-Item -LiteralPath $userGo }
}
if (-not $go) { throw '缺少 Go 1.22+，无法构建 Native Host 和安装器。' }
$npmPath = if ($npm.PSObject.Properties['Source']) { [string]$npm.Source } else { [string]$npm.FullName }
$goPath = if ($go.PSObject.Properties['Source']) { [string]$go.Source } else { [string]$go.FullName }
if ([string]::IsNullOrWhiteSpace($env:GOCACHE)) {
    $env:GOCACHE = Join-Path $env:TEMP 'notion2dingding-go-release-cache'
}

Invoke-Checked -Command $npmPath -Arguments @('run', 'build:extension') -Failure '扩展构建失败'
Invoke-Checked -Command (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repositoryRoot 'scripts\build-native-host.ps1')) `
    -Failure 'Native Host 构建失败'

$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ("notion2dingding-release-" + [Guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path $stagingRoot 'payload'
$bootstrapRoot = Join-Path $stagingRoot 'bootstrap'
$storeExtensionRoot = Join-Path $stagingRoot 'edge-extension-store'
try {
    [IO.Directory]::CreateDirectory($payloadRoot) | Out-Null
    [IO.Directory]::CreateDirectory($bootstrapRoot) | Out-Null

    # 开发版 manifest 需要 key 来固定本地加载时的扩展 ID；Edge Add-ons
    # 会拒绝包含 key 的商店包，因此仅在隔离的发布副本中移除此字段。
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'dist\edge-extension') `
        -Destination $storeExtensionRoot -Recurse -Force
    $storeManifestPath = Join-Path $storeExtensionRoot 'manifest.json'
    $storeManifest = Get-Content -LiteralPath $storeManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $storeManifest.PSObject.Properties['key']) {
        throw '开发版扩展清单缺少 key，无法推导固定扩展 ID。'
    }
    [void]$storeManifest.PSObject.Properties.Remove('key')
    [IO.File]::WriteAllText(
        $storeManifestPath,
        ($storeManifest | ConvertTo-Json -Depth 20),
        [Text.UTF8Encoding]::new($false)
    )

    $payloadFiles = @(
        'package.json',
        'apps\edge-extension\manifest.json',
        'dist\native-host\notion2dingding-host.exe',
        'scripts\install-release.ps1',
        'scripts\install-local-tool.ps1',
        'scripts\install-native-host.ps1',
        'scripts\Install-Notion2DingDing.cmd',
        'scripts\Uninstall-Notion2DingDing.cmd',
        'scripts\migrate-notion-to-dingtalk.mjs',
        'scripts\convert-notion-export.ps1',
        'scripts\notion-html-columns.lua',
        'scripts\normalize-notion-docx-layout.ps1',
        'scripts\test-docx-assets.ps1',
        'scripts\notion2dingding.ps1',
        'scripts\diagnose-local-tool.ps1',
        'scripts\notion2dingding-gui.ps1',
        'scripts\launch-notion2dingding-gui.vbs',
        'PRIVACY.md',
        'THIRD_PARTY_NOTICES.md',
        'docs\release-installation.md'
    )
    foreach ($relative in $payloadFiles) {
        Copy-ReleaseFile -Source (Join-Path $repositoryRoot $relative) -Destination (Join-Path $payloadRoot $relative)
    }

    $developmentExtensionId = Get-ExtensionIdFromKey -Key ([string]$extensionManifest.key)
    [IO.File]::WriteAllText(
        (Join-Path $payloadRoot 'release-config.json'),
        ([ordered]@{
            version = $version
            developmentExtensionId = $developmentExtensionId
            publishedExtensionId = $PublishedExtensionId
        } | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )

    if (Test-Path -LiteralPath $releaseDirectory) {
        Remove-Item -LiteralPath $releaseDirectory -Recurse -Force
    }
    [IO.Directory]::CreateDirectory($releaseDirectory) | Out-Null

    $extensionZip = Join-Path $releaseDirectory "Notion2DingDing-Edge-v$version.zip"
    Compress-Archive -Path (Join-Path $storeExtensionRoot '*') -DestinationPath $extensionZip -CompressionLevel Optimal

    $fallbackZip = Join-Path $releaseDirectory "Notion2DingDing-Setup-Files-v$version.zip"
    Compress-Archive -Path (Join-Path $payloadRoot '*') -DestinationPath $fallbackZip -CompressionLevel Optimal

    $payloadZip = Join-Path $bootstrapRoot 'payload.zip'
    Compress-Archive -Path (Join-Path $payloadRoot '*') -DestinationPath $payloadZip -CompressionLevel Optimal
    Copy-ReleaseFile -Source (Join-Path $repositoryRoot 'scripts\release-installer\main.go') -Destination (Join-Path $bootstrapRoot 'main.go')
    $setupExe = Join-Path $releaseDirectory 'Notion2DingDing-Setup.exe'
    Push-Location $bootstrapRoot
    try {
        Invoke-Checked -Command $goPath -Arguments @('build', '-trimpath', '-ldflags=-s -w', '-o', $setupExe, 'main.go') -Failure 'Windows 安装器构建失败'
    }
    finally {
        Pop-Location
    }

    $publishedReady = -not [string]::IsNullOrWhiteSpace($PublishedExtensionId)
    $releaseManifestPath = Join-Path $releaseDirectory 'release-manifest.json'
    $artifactNames = @(
        [IO.Path]::GetFileName($setupExe),
        [IO.Path]::GetFileName($extensionZip),
        [IO.Path]::GetFileName($fallbackZip)
    )
    $artifactRecords = @(
        foreach ($name in $artifactNames) {
            $path = Join-Path $releaseDirectory $name
            [ordered]@{
                name = $name
                bytes = (Get-Item -LiteralPath $path).Length
                sha256 = Get-Sha256 -Path $path
            }
        }
    )
    [IO.File]::WriteAllText(
        $releaseManifestPath,
        ([ordered]@{
            product = 'Notion2DingDing'
            version = $version
            builtAt = [DateTime]::UtcNow.ToString('o')
            microsoftStoreId = if ($storeIdentity) { [string]$storeIdentity.microsoftStoreId } else { '' }
            productId = if ($storeIdentity) { [string]$storeIdentity.productId } else { '' }
            developmentExtensionId = $developmentExtensionId
            publishedExtensionId = $PublishedExtensionId
            edgeSubmissionReady = $publishedReady
            codeSigned = $false
            artifacts = $artifactRecords
        } | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    $checksumLines = @($artifactRecords | ForEach-Object { "$($_.sha256)  $($_.name)" })
    [IO.File]::WriteAllLines(
        (Join-Path $releaseDirectory 'checksums.sha256'),
        $checksumLines,
        [Text.UTF8Encoding]::new($false)
    )
    Copy-ReleaseFile -Source (Join-Path $repositoryRoot 'PRIVACY.md') -Destination (Join-Path $releaseDirectory 'PRIVACY.md')
    Copy-ReleaseFile -Source (Join-Path $repositoryRoot 'THIRD_PARTY_NOTICES.md') -Destination (Join-Path $releaseDirectory 'THIRD_PARTY_NOTICES.md')
    Copy-ReleaseFile -Source (Join-Path $repositoryRoot 'docs\release-installation.md') -Destination (Join-Path $releaseDirectory '安装与升级说明.md')

    [ordered]@{
        success = $true
        version = $version
        releaseDirectory = $releaseDirectory
        edgeSubmissionReady = $publishedReady
        publishedExtensionId = $PublishedExtensionId
        artifacts = $artifactRecords
    } | ConvertTo-Json -Depth 8
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
