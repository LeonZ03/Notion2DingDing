[CmdletBinding()]
param(
    [ValidateSet('InstallOrUpgrade', 'Uninstall')]
    [string]$Action = 'InstallOrUpgrade',

    [switch]$SkipDependencyInstall,
    [switch]$SkipDependencyCheck,
    [switch]$SkipRegistry,
    [switch]$Quiet,
    [switch]$RemoveDingtalkLogin,
    [switch]$SkipUserPathUpdate,

    [string]$LocalInstallDirectory,
    [string]$DataDirectory,
    [string]$LauncherDirectory,
    [string]$StartMenuDirectory,
    [string]$NativeInstallDirectory,
    [string]$RegistryPath,
    [string]$UninstallRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Notion2DingDing',
    [string]$DependencyDirectory,
    [string]$DwsCommandPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'uninstall-support.ps1')
if (-not $DependencyDirectory) { $DependencyDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Notion2DingDingDependencies' }
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$localInstaller = Join-Path $packageRoot 'scripts\install-local-tool.ps1'
$nativeInstaller = Join-Path $packageRoot 'scripts\install-native-host.ps1'
$hostExe = Join-Path $packageRoot 'dist\native-host\notion2dingding-host.exe'
$releaseConfigPath = Join-Path $packageRoot 'release-config.json'
$downloadOrigin = 'https://notion2dingding.leonz03.dpdns.org'
$publishedExtensionId = ''
if (Test-Path -LiteralPath $releaseConfigPath -PathType Leaf) {
    try {
        $releaseConfig = Get-Content -LiteralPath $releaseConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $publishedExtensionId = [string]$releaseConfig.publishedExtensionId
        if ($publishedExtensionId -and $publishedExtensionId -notmatch '^[a-p]{32}$') {
            throw 'publishedExtensionId 格式无效。'
        }
    }
    catch {
        throw "发布配置损坏：$($_.Exception.Message)"
    }
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    if (-not $Quiet) { Write-Host $Message -ForegroundColor Cyan }
}

function Refresh-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
}

function Resolve-CommandPath {
    param([Parameter(Mandatory)][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { return $null }
    if ($command.Source) { return $command.Source }
    return $command.Path
}

function Test-Node24 {
    $node = Resolve-CommandPath -Name 'node.exe'
    if (-not $node) { $node = Resolve-CommandPath -Name 'node' }
    if (-not $node) { return $false }
    $version = (& $node --version 2>$null | Out-String).Trim()
    $match = [regex]::Match($version, '^v(?<major>\d+)\.')
    return $match.Success -and [int]$match.Groups['major'].Value -ge 24
}

function Test-Pandoc3 {
    $pandoc = Resolve-CommandPath -Name 'pandoc.exe'
    if (-not $pandoc) { $pandoc = Resolve-CommandPath -Name 'pandoc' }
    if (-not $pandoc) { return $false }
    $firstLine = ((& $pandoc --version 2>$null | Out-String) -split "`r?`n")[0]
    $match = [regex]::Match($firstLine, '(?<major>\d+)\.')
    return $match.Success -and [int]$match.Groups['major'].Value -ge 3
}

function Test-DwsVersion {
    $dws = Resolve-CommandPath -Name 'dws.cmd'
    if (-not $dws) { $dws = Resolve-CommandPath -Name 'dws' }
    if (-not $dws) { return $false }
    $version = (& $dws --version 2>$null | Out-String).Trim()
    return $version -match 'v1\.0\.59(?:\D|$)'
}

function Add-UserPathEntry {
    param([Parameter(Mandatory)][string]$Directory)

    $resolvedDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $alreadyPresent = $false
    foreach ($entry in $entries) {
        try {
            if ([IO.Path]::GetFullPath($entry).TrimEnd('\').Equals($resolvedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                $alreadyPresent = $true
                break
            }
        }
        catch {
            # 保留用户 PATH 中无法解析的既有条目，不让它阻断安装。
        }
    }
    if (-not $alreadyPresent) {
        $updated = (@($resolvedDirectory) + $entries) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
    }
    Refresh-ProcessPath
    $env:Path = "$resolvedDirectory;$env:Path"
}

function Install-MirroredDependency {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$ArchiveName,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$VersionPattern
    )
    $installDirectory = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Programs\Notion2DingDingDependencies\$Name\$Version"))
    $dependencyRoot = Split-Path -Parent $installDirectory
    $ownerMarker = Join-Path $installDirectory '.n2dd-dependency.json'
    if (Test-Path -LiteralPath $installDirectory) {
        if (-not (Test-Path -LiteralPath $ownerMarker -PathType Leaf)) {
            throw "依赖目录没有本项目所有权标记，已停止覆盖：$installDirectory"
        }
        $owner = Get-Content -LiteralPath $ownerMarker -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($owner.owner -ne 'Notion2DingDing' -or $owner.sha256 -ne $Sha256) {
            throw "依赖目录所有权或版本校验失败：$installDirectory"
        }
        $existingExe = Join-Path $installDirectory $Executable
        if ((Test-Path -LiteralPath $existingExe -PathType Leaf) -and ((& $existingExe --version | Out-String) -match $VersionPattern)) {
            Add-UserPathEntry -Directory $installDirectory
            return
        }
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("notion2dingding-dependency-" + [guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $tempRoot 'dependency.zip'
    $expandPath = Join-Path $tempRoot 'expanded'
    $stagingPath = "$installDirectory.staging-" + [guid]::NewGuid().ToString('N')

    try {
        Write-Step "正在下载安装 $Name $Version（项目下载源）…"
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        # 隐藏 PowerShell 原生 Web 请求字节输出，只展示可读的安装步骤。
        $ProgressPreference = 'SilentlyContinue'
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -Uri "$downloadOrigin/downloads/$ArchiveName" -OutFile $archivePath -UseBasicParsing
                break
            }
            catch { if ($attempt -eq 3) { throw } }
        }

        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -ne $Sha256) {
            throw "$Name 下载校验失败：期望 $Sha256，实际 $actualHash。"
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $expandPath -Force
        $executables = @(Get-ChildItem -LiteralPath $expandPath -Filter $Executable -File -Recurse)
        if ($executables.Count -ne 1) {
            throw "$Name 压缩包结构无效：应包含 1 个 $Executable。"
        }
        $versionOutput = & $executables[0].FullName --version | Out-String
        if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch $VersionPattern) { throw "$Name 版本验证失败。" }
        $payloadDirectory = Split-Path -Parent $executables[0].FullName
        New-Item -ItemType Directory -Path $dependencyRoot -Force | Out-Null
        Move-Item -LiteralPath $payloadDirectory -Destination $stagingPath
        [ordered]@{
            owner = 'Notion2DingDing'
            version = $Version
            source = "$downloadOrigin/downloads/$ArchiveName"
            sha256 = $Sha256
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stagingPath '.n2dd-dependency.json') -Encoding UTF8

        if (Test-Path -LiteralPath $installDirectory) {
            Remove-Item -LiteralPath $installDirectory -Recurse -Force
        }
        Move-Item -LiteralPath $stagingPath -Destination $installDirectory
        Add-UserPathEntry -Directory $installDirectory
    }
    finally {
        if (Test-Path -LiteralPath $stagingPath) {
            Remove-Item -LiteralPath $stagingPath -Recurse -Force
        }
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Install-Dependencies {
    if (-not (Test-Node24)) {
        Install-MirroredDependency -Name 'Node' -Version '24.16.0' -ArchiveName 'node-v24.16.0-win-x64.zip' -Sha256 'EDACA9BD58EC8E92037DAC4E877D52F6B8F430B81C18B57E264B4E2FB111CD56' -Executable 'node.exe' -VersionPattern '^v24\.16\.0\s*$'
    }
    if (-not (Test-Pandoc3)) {
        Install-MirroredDependency -Name 'Pandoc' -Version '3.11' -ArchiveName 'pandoc-3.11-windows-x86_64.zip' -Sha256 '2AB72BAF2399450E148DDF7A2A8689806C42E1BBA71862B57E220FD9B8456D3D' -Executable 'pandoc.exe' -VersionPattern '^pandoc 3\.11\s'
    }
    if (-not (Test-DwsVersion)) {
        Install-MirroredDependency -Name 'Dws' -Version '1.0.59' -ArchiveName 'dws-windows-amd64-1.0.59.zip' -Sha256 '5393A0D5E00C70B58833C60610AD3A772926CA5E4EB38C360928E3D2552451BC' -Executable 'dws.exe' -VersionPattern 'v1\.0\.59(?:\D|$)'
    }
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $output = & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw $output.Trim()
    }
    try {
        return $output | ConvertFrom-Json
    }
    catch {
        throw "安装组件没有返回有效结果：$($output.Trim())"
    }
}

function Add-OptionalArgument {
    param(
        [Parameter(Mandatory)][System.Collections.ArrayList]$Arguments,
        [Parameter(Mandatory)][string]$Name,
        [string]$Value
    )
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        [void]$Arguments.Add($Name)
        [void]$Arguments.Add($Value)
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Notion2DingDing 本地助手只支持 Windows 10/11。'
}
foreach ($required in @($localInstaller, $nativeInstaller)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "安装包不完整，缺少：$required"
    }
}

try {
    if ($Action -eq 'Uninstall') {
        if (-not $LocalInstallDirectory) { $LocalInstallDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Notion2DingDing' }
        if (-not $SkipRegistry) { Assert-N2ddUninstallRegistration -Path $UninstallRegistryPath -InstallDirectory $LocalInstallDirectory }
        $nativePath = if ($NativeInstallDirectory) { $NativeInstallDirectory } else { Join-Path $env:LOCALAPPDATA 'Programs\Notion2DingDingNativeHost' }
        $runningHost = @(Get-Process -Name 'notion2dingding-host' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $nativePath 'notion2dingding-host.exe') })
        if ($runningHost.Count) { throw '本地助手仍在运行。请等待迁移结束，完全关闭 Edge 后重新卸载。' }
        $effectiveData = if ($DataDirectory) { $DataDirectory } else { Join-Path $env:LOCALAPPDATA 'Notion2DingDing' }
        foreach ($target in @($LocalInstallDirectory, $nativePath, $effectiveData)) { $null = Assert-N2ddDirectory -Path $target }
        # 在清除登录状态、删除程序之前完成目录安全预检。
        $null = @(Get-N2ddManagedDependencies -Directory $DependencyDirectory)
        # 在移除专属 dws 前执行用户明确选择的退出登录，不读取或输出凭据。
        if ($RemoveDingtalkLogin) {
            if (-not $DwsCommandPath) {
                $managedDws = Join-Path $DependencyDirectory 'Dws\1.0.59\dws.exe'
                if (Test-Path -LiteralPath $managedDws -PathType Leaf) { $DwsCommandPath = $managedDws }
                else { $DwsCommandPath = Resolve-CommandPath -Name 'dws' }
            }
            if (-not $DwsCommandPath) { throw '未找到 dws，无法清除登录状态；可取消该选项后重试卸载。' }
            $dwsVersion = (& $DwsCommandPath --version 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $dwsVersion -notmatch 'v1\.0\.59(?:\D|$)') { throw 'dws 版本不匹配，未执行退出登录。' }
            $null = & $DwsCommandPath auth logout 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'dws 清除登录状态失败，尚未卸载；请检查后重试。' }
        }
        Write-Step '正在卸载 Native Host…'
        $nativeArguments = [System.Collections.ArrayList]@('-Action', 'Uninstall')
        Add-OptionalArgument -Arguments $nativeArguments -Name '-InstallDirectory' -Value $NativeInstallDirectory
        Add-OptionalArgument -Arguments $nativeArguments -Name '-RegistryPath' -Value $RegistryPath
        if ($SkipRegistry) { [void]$nativeArguments.Add('-SkipRegistry') }
        $nativeResult = Invoke-Installer -Script $nativeInstaller -Arguments @($nativeArguments)

        # 依赖清理失败时保留安装版卸载入口，便于用户修复后重试。
        $dependenciesResult = Remove-N2ddManagedDependencies -Directory $DependencyDirectory -SkipUserPathUpdate:$SkipUserPathUpdate

        Write-Step '正在卸载本地迁移核心…'
        $localArguments = [System.Collections.ArrayList]@('-Action', 'Uninstall')
        Add-OptionalArgument -Arguments $localArguments -Name '-InstallDirectory' -Value $LocalInstallDirectory
        Add-OptionalArgument -Arguments $localArguments -Name '-DataDirectory' -Value $DataDirectory
        Add-OptionalArgument -Arguments $localArguments -Name '-LauncherDirectory' -Value $LauncherDirectory
        Add-OptionalArgument -Arguments $localArguments -Name '-StartMenuDirectory' -Value $StartMenuDirectory
        $localResult = Invoke-Installer -Script $localInstaller -Arguments @($localArguments)

        if (-not $SkipRegistry -and (Test-Path -LiteralPath $UninstallRegistryPath)) {
            Assert-N2ddUninstallRegistration -Path $UninstallRegistryPath -InstallDirectory $LocalInstallDirectory
            Remove-Item -LiteralPath $UninstallRegistryPath -Force
            if (Test-Path -LiteralPath $UninstallRegistryPath) { throw 'Windows 卸载注册项清理失败。' }
        }

        [ordered]@{
            success = $true
            action = 'uninstall'
            localTool = $localResult
            nativeHost = $nativeResult
            dependencies = $dependenciesResult
            dingtalkLoginCleared = [bool]$RemoveDingtalkLogin
        } | ConvertTo-Json -Depth 10
        exit 0
    }

    if (-not $SkipDependencyInstall) {
        Install-Dependencies
    }

    if ([string]::IsNullOrWhiteSpace($LocalInstallDirectory)) {
        $LocalInstallDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Notion2DingDing'
    }
    if ([string]::IsNullOrWhiteSpace($NativeInstallDirectory)) {
        $NativeInstallDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Notion2DingDingNativeHost'
    }
    if (-not $SkipRegistry) { Assert-N2ddUninstallRegistration -Path $UninstallRegistryPath -InstallDirectory $LocalInstallDirectory }
    $localAction = if (Test-Path -LiteralPath $LocalInstallDirectory) { 'Upgrade' } else { 'Install' }
    $nativeAction = if (Test-Path -LiteralPath $NativeInstallDirectory) { 'Upgrade' } else { 'Install' }

    $localVerb = if ($localAction -eq 'Install') { '安装' } else { '升级' }
    Write-Step "正在${localVerb}本地迁移核心…"
    $localArguments = [System.Collections.ArrayList]@('-Action', $localAction)
    Add-OptionalArgument -Arguments $localArguments -Name '-InstallDirectory' -Value $LocalInstallDirectory
    Add-OptionalArgument -Arguments $localArguments -Name '-DataDirectory' -Value $DataDirectory
    Add-OptionalArgument -Arguments $localArguments -Name '-LauncherDirectory' -Value $LauncherDirectory
    Add-OptionalArgument -Arguments $localArguments -Name '-StartMenuDirectory' -Value $StartMenuDirectory
    if ($SkipDependencyCheck) { [void]$localArguments.Add('-SkipDependencyCheck') }
    $localResult = Invoke-Installer -Script $localInstaller -Arguments @($localArguments)

    $nativeVerb = if ($nativeAction -eq 'Install') { '安装' } else { '升级' }
    Write-Step "正在$nativeVerb Edge Native Host…"
    $nativeArguments = [System.Collections.ArrayList]@('-Action', $nativeAction, '-HostExePath', $hostExe)
    Add-OptionalArgument -Arguments $nativeArguments -Name '-InstallDirectory' -Value $NativeInstallDirectory
    Add-OptionalArgument -Arguments $nativeArguments -Name '-RegistryPath' -Value $RegistryPath
    Add-OptionalArgument -Arguments $nativeArguments -Name '-AdditionalExtensionId' -Value $publishedExtensionId
    if ($SkipRegistry) { [void]$nativeArguments.Add('-SkipRegistry') }
    $nativeResult = Invoke-Installer -Script $nativeInstaller -Arguments @($nativeArguments)

    $effectiveData = if ($DataDirectory) { $DataDirectory } else { Join-Path $env:LOCALAPPDATA 'Notion2DingDing' }
    $effectiveLauncher = if ($LauncherDirectory) { $LauncherDirectory } else { Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps' }
    $effectiveStartMenu = if ($StartMenuDirectory) { $StartMenuDirectory } else { Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
    Install-N2ddUninstallEntry -InstallDirectory $LocalInstallDirectory -DataDirectory $effectiveData -LauncherDirectory $effectiveLauncher -StartMenuDirectory $effectiveStartMenu -NativeInstallDirectory $NativeInstallDirectory -DependencyDirectory $DependencyDirectory -RegistryPath $RegistryPath -UninstallRegistryPath $UninstallRegistryPath -SkipRegistry:$SkipRegistry -SkipUserPathUpdate:$SkipUserPathUpdate

    [ordered]@{
        success = $true
        action = 'install_or_upgrade'
        localTool = $localResult
        nativeHost = $nativeResult
        requiresEdgeRestart = $true
        next = @(
            '完全关闭并重新打开 Edge。',
            '打开 Notion2DingDing 扩展，完成钉钉登录和保存位置选择。',
            '状态变为绿色后，日常迁移只需使用 Edge 扩展。'
        )
    } | ConvertTo-Json -Depth 10
}
catch {
    [ordered]@{
        success = $false
        action = $Action.ToLowerInvariant()
        error = [ordered]@{
            code = 'RELEASE_INSTALL_FAILED'
            message = $_.Exception.Message
        }
    } | ConvertTo-Json -Depth 6
    exit 1
}
