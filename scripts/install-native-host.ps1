[CmdletBinding()]
param(
    [ValidateSet('Install', 'Upgrade', 'Status', 'Uninstall')]
    [string]$Action = 'Install',

    [ValidatePattern('^[a-p]{32}$')]
    [string]$ExtensionId,

    [ValidatePattern('^[a-p]{32}$')]
    [string]$AdditionalExtensionId,

    [string]$HostExePath,

    [string]$InstallDirectory,

    [string]$RegistryPath,

    [switch]$SkipRegistry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hostName = 'com.leonz03.notion2dingding'
$ownershipId = 'com.leonz03.notion2dingding.native-host'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

if ([string]::IsNullOrWhiteSpace($HostExePath)) {
    $HostExePath = Join-Path $repositoryRoot 'dist\native-host\notion2dingding-host.exe'
}
if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
    $InstallDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Notion2DingDingNativeHost'
}
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$installedHostPath = Join-Path $InstallDirectory 'notion2dingding-host.exe'
$manifestPath = Join-Path $InstallDirectory "$hostName.json"
$markerPath = Join-Path $InstallDirectory '.n2dd-native-host.json'
if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    $RegistryPath = "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\$hostName"
}
$registryPath = $RegistryPath

$localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
if (-not $InstallDirectory.StartsWith("$localAppData\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Native Host 安装目录必须位于当前用户 LOCALAPPDATA 内：$InstallDirectory"
}
if (-not $registryPath.StartsWith('HKCU:\Software\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Native Host 注册表位置必须位于 HKCU:\Software 下：$registryPath"
}

function Get-ExtensionIdFromKey {
    $extensionManifestPath = Join-Path $repositoryRoot 'apps\edge-extension\manifest.json'
    $manifest = Get-Content -LiteralPath $extensionManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$manifest.key)) {
        throw "扩展 manifest 缺少固定公钥：$extensionManifestPath"
    }
    $keyBytes = [Convert]::FromBase64String([string]$manifest.key)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($keyBytes)
    }
    finally {
        $sha.Dispose()
    }
    $alphabet = 'abcdefghijklmnop'
    $builder = [Text.StringBuilder]::new(32)
    foreach ($value in $hash[0..15]) {
        [void]$builder.Append($alphabet[[int]($value -shr 4)])
        [void]$builder.Append($alphabet[[int]($value -band 15)])
    }
    return $builder.ToString()
}

function Read-OwnerMarker {
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "Native Host 目录缺少所有权标记，拒绝修改或删除：$markerPath"
    }
    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Native Host 所有权标记损坏，拒绝修改或删除：$markerPath"
    }
    if ($marker.ownershipId -ne $ownershipId) {
        throw "Native Host 所有权标记不匹配，拒绝修改或删除：$markerPath"
    }
    return $marker
}

function Write-Utf8Json {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-StatusResult {
    $registryManifest = $null
    if ($SkipRegistry) {
        $registryManifest = $manifestPath
    }
    elseif (Test-Path -LiteralPath $registryPath) {
        $registryManifest = [string](Get-Item -LiteralPath $registryPath).GetValue('')
    }
    $markerValid = $false
    if (Test-Path -LiteralPath $InstallDirectory) {
        try {
            [void](Read-OwnerMarker)
            $markerValid = $true
        }
        catch {
            $markerValid = $false
        }
    }
    return [ordered]@{
        success = $true
        action = 'status'
        installed = (
            $markerValid -and
            (Test-Path -LiteralPath $installedHostPath -PathType Leaf) -and
            (Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
            $registryManifest -eq $manifestPath
        )
        extensionId = $ExtensionId
        hostPath = $installedHostPath
        manifestPath = $manifestPath
        registryManifest = $registryManifest
        registrySkipped = [bool]$SkipRegistry
        markerValid = $markerValid
    }
}

if ([string]::IsNullOrWhiteSpace($ExtensionId)) {
    $ExtensionId = Get-ExtensionIdFromKey
}
$extensionIds = @(
    @($ExtensionId, $AdditionalExtensionId) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

try {
    if ($Action -eq 'Status') {
        Get-StatusResult | ConvertTo-Json -Depth 6
        exit 0
    }

    if ($Action -eq 'Uninstall') {
        if (Test-Path -LiteralPath $InstallDirectory) {
            [void](Read-OwnerMarker)
        }
        if (-not $SkipRegistry -and (Test-Path -LiteralPath $registryPath)) {
            $registeredManifest = [string](Get-Item -LiteralPath $registryPath).GetValue('')
            if ($registeredManifest -ne $manifestPath) {
                throw "注册表指向非本项目清单，拒绝删除：$registeredManifest"
            }
            Remove-Item -LiteralPath $registryPath -Force
        }
        if (Test-Path -LiteralPath $InstallDirectory) {
            $resolvedRoot = [IO.Path]::GetPathRoot($InstallDirectory).TrimEnd('\')
            if ($InstallDirectory.Equals($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "拒绝删除磁盘根目录：$InstallDirectory"
            }
            Remove-Item -LiteralPath $InstallDirectory -Recurse -Force
        }
        [ordered]@{
            success = $true
            action = 'uninstall'
            installDirectoryRemoved = -not (Test-Path -LiteralPath $InstallDirectory)
            registryRemoved = $SkipRegistry -or -not (Test-Path -LiteralPath $registryPath)
        } | ConvertTo-Json -Depth 4
        exit 0
    }

    $alreadyInstalled = Test-Path -LiteralPath $InstallDirectory
    if ($Action -eq 'Install' -and $alreadyInstalled) {
        throw 'Native Host 已安装；请使用 -Action Upgrade。'
    }
    if ($Action -eq 'Upgrade' -and -not $alreadyInstalled) {
        throw 'Native Host 尚未安装；请先使用 -Action Install。'
    }
    if ($alreadyInstalled) {
        [void](Read-OwnerMarker)
    }
    if (-not (Test-Path -LiteralPath $HostExePath -PathType Leaf)) {
        throw "Native Host 可执行文件不存在，请先运行 npm run build:native：$HostExePath"
    }

    $resolvedHostPath = (Resolve-Path -LiteralPath $HostExePath).Path
    $stagingDirectory = "$InstallDirectory.staging-$PID-$([Guid]::NewGuid().ToString('N'))"
    $backupDirectory = "$InstallDirectory.backup-$PID-$([Guid]::NewGuid().ToString('N'))"
    $registryExisted = -not $SkipRegistry -and (Test-Path -LiteralPath $registryPath)
    $previousRegistryManifest = $null
    if ($registryExisted) {
        $previousRegistryManifest = [string](Get-Item -LiteralPath $registryPath).GetValue('')
    }
    $existingMoved = $false
    $newInstalled = $false
    $registryWritten = $false
    try {
        [IO.Directory]::CreateDirectory($stagingDirectory) | Out-Null
        Copy-Item -LiteralPath $resolvedHostPath -Destination (Join-Path $stagingDirectory 'notion2dingding-host.exe')
        Write-Utf8Json -Path (Join-Path $stagingDirectory "$hostName.json") -Value ([ordered]@{
            name = $hostName
            description = 'Notion2DingDing Windows Native Messaging Host'
            path = $installedHostPath
            type = 'stdio'
            allowed_origins = @($extensionIds | ForEach-Object { "chrome-extension://$_/" })
        })
        Write-Utf8Json -Path (Join-Path $stagingDirectory '.n2dd-native-host.json') -Value ([ordered]@{
            ownershipId = $ownershipId
            markerVersion = 1
            extensionId = $ExtensionId
            extensionIds = $extensionIds
            installedAt = [DateTime]::UtcNow.ToString('o')
        })

        if ($alreadyInstalled) {
            Move-Item -LiteralPath $InstallDirectory -Destination $backupDirectory
            $existingMoved = $true
        }
        Move-Item -LiteralPath $stagingDirectory -Destination $InstallDirectory
        $newInstalled = $true
        if (-not $SkipRegistry) {
            New-Item -Path $registryPath -Force | Out-Null
            Set-Item -LiteralPath $registryPath -Value $manifestPath
            $registryWritten = $true
        }
        if (Test-Path -LiteralPath $backupDirectory) {
            Remove-Item -LiteralPath $backupDirectory -Recurse -Force
            $existingMoved = $false
        }
    }
    catch {
        if ($newInstalled -and (Test-Path -LiteralPath $InstallDirectory)) {
            [void](Read-OwnerMarker)
            Remove-Item -LiteralPath $InstallDirectory -Recurse -Force
            $newInstalled = $false
        }
        if ($existingMoved -and (Test-Path -LiteralPath $backupDirectory)) {
            Move-Item -LiteralPath $backupDirectory -Destination $InstallDirectory
            $existingMoved = $false
        }
        if ($registryWritten) {
            if ($registryExisted) {
                New-Item -Path $registryPath -Force | Out-Null
                Set-Item -LiteralPath $registryPath -Value $previousRegistryManifest
            }
            elseif (Test-Path -LiteralPath $registryPath) {
                Remove-Item -LiteralPath $registryPath -Force
            }
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $stagingDirectory) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
        }
    }

    $status = Get-StatusResult
    $status.action = $Action.ToLowerInvariant()
    $status | ConvertTo-Json -Depth 6
}
catch {
    [ordered]@{
        success = $false
        action = $Action.ToLowerInvariant()
        error = [ordered]@{
            code = 'NATIVE_HOST_MANAGEMENT_FAILED'
            message = $_.Exception.Message
        }
    } | ConvertTo-Json -Depth 5
    exit 1
}
