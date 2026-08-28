Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$installerPath = Join-Path $repositoryRoot 'scripts\install-native-host.ps1'
$nonce = [Guid]::NewGuid().ToString('N')
$temporaryRoot = Join-Path $env:LOCALAPPDATA "Temp\notion2dingding-stage5-install-$nonce"
$installDirectory = Join-Path $temporaryRoot 'NativeHost'
$registryRoot = "HKCU:\Software\Notion2DingDingStage5Tests\$nonce"
$registryPath = "$registryRoot\NativeMessagingHost"
$expectedExtensionId = 'hheldkapioofhdbblmgfokdnpgfgaafo'

function Invoke-Installer {
    param([Parameter(Mandatory)][string]$Action)
    $output = & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $installerPath `
        -Action $Action `
        -InstallDirectory $installDirectory `
        -RegistryPath $registryPath `
        -SkipRegistry | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Native Host $Action 失败：$output"
    }
    return $output | ConvertFrom-Json
}

try {
    $installed = Invoke-Installer -Action Install
    if (-not $installed.success -or -not $installed.installed) {
        throw '隔离 Native Host 安装没有报告成功。'
    }
    if ($installed.extensionId -ne $expectedExtensionId) {
        throw "固定扩展 ID 不匹配：$($installed.extensionId)"
    }
    $manifest = Get-Content -LiteralPath $installed.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.name -ne 'com.leonz03.notion2dingding') {
        throw 'Native Messaging 清单名称不正确。'
    }
    if ($manifest.path -ne $installed.hostPath) {
        throw 'Native Messaging 清单没有指向安装后的 Host。'
    }
    if ($manifest.allowed_origins.Count -ne 1 -or $manifest.allowed_origins[0] -ne "chrome-extension://$expectedExtensionId/") {
        throw 'Native Messaging allowed_origins 不是固定扩展 ID。'
    }

    $status = Invoke-Installer -Action Status
    if (-not $status.installed -or -not $status.markerValid) {
        throw '安装后的状态检查未通过。'
    }
    $upgraded = Invoke-Installer -Action Upgrade
    if (-not $upgraded.installed) {
        throw '隔离 Native Host 升级未通过。'
    }

    & node --test (Join-Path $repositoryRoot 'tests\stage5\native-host.test.mjs')
    if ($LASTEXITCODE -ne 0) {
        throw "阶段 5 Native Host 集成测试失败，退出码：$LASTEXITCODE"
    }

    $uninstalled = Invoke-Installer -Action Uninstall
    if (-not $uninstalled.installDirectoryRemoved -or -not $uninstalled.registryRemoved) {
        throw '隔离 Native Host 卸载没有清理全部项目资源。'
    }
    if (Test-Path -LiteralPath $installDirectory) {
        throw "隔离 Native Host 目录仍然存在：$installDirectory"
    }
    if (Test-Path -LiteralPath $registryPath) {
        throw "隔离 Native Host 注册表仍然存在：$registryPath"
    }

    [ordered]@{
        success = $true
        extensionId = $expectedExtensionId
        installUpgradeUninstall = $true
        hostRestart = $true
        fixtures = @('ordinary', 'long-page', 'multi-image')
        pageCompletenessGuard = $true
        sourceBytesEquivalent = $true
        cleanupVerified = $true
    } | ConvertTo-Json -Depth 5
}
finally {
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    $expectedPrefix = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Temp\notion2dingding-stage5-install-'))
    if (-not $resolvedTemporaryRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理未通过边界验证的阶段 5 临时目录：$resolvedTemporaryRoot"
    }
    if (Test-Path -LiteralPath $resolvedTemporaryRoot) {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $registryRoot) {
        Remove-Item -LiteralPath $registryRoot -Recurse -Force
    }
}
