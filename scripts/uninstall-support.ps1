# 安装与卸载共用的薄适配层；只能处理本项目拥有的目录和当前用户注册项。
function Assert-N2ddDirectory {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $userRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\'
    if (-not $full.StartsWith($userRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "目录不在当前用户 LOCALAPPDATA 内：$full" }
    if (Test-Path -LiteralPath $full) {
        $items = @(Get-Item -LiteralPath $full -Force) + @(Get-ChildItem -LiteralPath $full -Force -Recurse)
        if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw "目录含链接或重解析点，拒绝递归清理：$full" }
    }
    return $full
}

function Get-N2ddManagedDependencies {
    param([string]$Directory)
    $root = Assert-N2ddDirectory -Path $Directory
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($name in @('Node', 'Pandoc', 'Dws')) {
        $parent = Join-Path $root $name
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
        foreach ($version in @(Get-ChildItem -LiteralPath $parent -Directory -Force)) {
            $markerPath = Join-Path $version.FullName '.n2dd-dependency.json'
            if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { continue }
            try { $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if ($marker.owner -eq 'Notion2DingDing' -and $marker.version -eq $version.Name -and $marker.sha256 -match '^[a-fA-F0-9]{64}$') {
                Assert-N2ddDirectory -Path $version.FullName
            }
        }
    }
}

function Remove-N2ddManagedDependencies {
    param([string]$Directory, [switch]$SkipUserPathUpdate)
    $removed = @()
    foreach ($path in @(Get-N2ddManagedDependencies -Directory $Directory)) {
        $resolved = Assert-N2ddDirectory -Path $path
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $resolved) { throw "依赖清理失败：$resolved" }
        $removed += $resolved
    }
    if (-not $SkipUserPathUpdate -and $removed.Count) {
        $entries = @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')
        $kept = @($entries | Where-Object {
            $entry = $_
            $match = $false
            foreach ($path in $removed) {
                try { if ([IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($entry)).TrimEnd('\').Equals($path, [StringComparison]::OrdinalIgnoreCase)) { $match = $true } } catch { }
            }
            -not $match
        })
        [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    }
    # 只删除空的父目录；其他版本、外来文件和共享安装保持不变。
    foreach ($name in @('Node', 'Pandoc', 'Dws', '')) {
        $parent = if ($name) { Join-Path $Directory $name } else { $Directory }
        if ((Test-Path -LiteralPath $parent -PathType Container) -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) { Remove-Item -LiteralPath $parent -Force }
    }
    return [ordered]@{ removedCount = $removed.Count; sharedDependenciesPreserved = $true }
}

function Assert-N2ddUninstallRegistration {
    param([string]$Path, [string]$InstallDirectory)
    if (-not $Path.StartsWith('HKCU:\Software\', [StringComparison]::OrdinalIgnoreCase)) { throw '卸载注册项必须位于 HKCU:\Software 下。' }
    if (Test-Path -LiteralPath $Path) {
        $entry = Get-ItemProperty -LiteralPath $Path
        if ($entry.N2DDOwnershipId -ne 'com.leonz03.notion2dingding.uninstaller' -or $entry.InstallLocation -ne $InstallDirectory) { throw '卸载注册项不属于本项目，拒绝覆盖或删除。' }
    }
}

function Install-N2ddUninstallEntry {
    param([string]$InstallDirectory, [string]$DataDirectory, [string]$LauncherDirectory, [string]$StartMenuDirectory, [string]$NativeInstallDirectory, [string]$DependencyDirectory, [string]$RegistryPath, [string]$UninstallRegistryPath, [switch]$SkipRegistry, [switch]$SkipUserPathUpdate)
    $maintenance = Join-Path $InstallDirectory 'maintenance'
    $files = @('install-release.ps1', 'install-local-tool.ps1', 'install-native-host.ps1', 'uninstall-support.ps1', 'uninstall-notion2dingding.ps1', 'launch-uninstall.vbs')
    foreach ($file in $files) {
        $destination = Join-Path $maintenance "scripts\$file"
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $destination -Force
    }
    $configuration = [ordered]@{ LocalInstallDirectory=$InstallDirectory; DataDirectory=$DataDirectory; LauncherDirectory=$LauncherDirectory; StartMenuDirectory=$StartMenuDirectory; NativeInstallDirectory=$NativeInstallDirectory; DependencyDirectory=$DependencyDirectory; RegistryPath=$RegistryPath; UninstallRegistryPath=$UninstallRegistryPath; SkipRegistry=[bool]$SkipRegistry; SkipUserPathUpdate=[bool]$SkipUserPathUpdate }
    [IO.File]::WriteAllText((Join-Path $maintenance 'uninstall-config.json'), ($configuration | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $launcher = Join-Path $maintenance 'scripts\launch-uninstall.vbs'
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcutDirectory = Join-Path $StartMenuDirectory 'Notion2DingDing'
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut((Join-Path $shortcutDirectory '卸载 Notion2DingDing.lnk'))
        $shortcut.TargetPath = $wscript
        $shortcut.Arguments = '"' + $launcher + '"'
        $shortcut.WorkingDirectory = $maintenance
        $shortcut.Description = '卸载本地助手，并选择是否清除钉钉登录状态'
        $shortcut.Save()
    } finally {
        if ($shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
    if (-not $SkipRegistry) {
        Assert-N2ddUninstallRegistration -Path $UninstallRegistryPath -InstallDirectory $InstallDirectory
        New-Item -Path $UninstallRegistryPath -Force | Out-Null
        $properties = @{ DisplayName='Notion2DingDing 本地助手'; DisplayVersion=$localResult.version; Publisher='Leon Z Tools'; InstallLocation=$InstallDirectory; UninstallString=('"' + $wscript + '" "' + $launcher + '"'); N2DDOwnershipId='com.leonz03.notion2dingding.uninstaller'; URLInfoAbout='https://notion2dingding.leonz03.dpdns.org/' }
        foreach ($key in $properties.Keys) { New-ItemProperty -LiteralPath $UninstallRegistryPath -Name $key -Value $properties[$key] -PropertyType String -Force | Out-Null }
        foreach ($key in @('NoModify','NoRepair')) { New-ItemProperty -LiteralPath $UninstallRegistryPath -Name $key -Value 1 -PropertyType DWord -Force | Out-Null }
    }
}
