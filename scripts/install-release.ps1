[CmdletBinding()]
param(
    [ValidateSet('InstallOrUpgrade', 'Uninstall')]
    [string]$Action = 'InstallOrUpgrade',

    [switch]$SkipDependencyInstall,
    [switch]$SkipDependencyCheck,
    [switch]$SkipRegistry,
    [switch]$Quiet,

    [string]$LocalInstallDirectory,
    [string]$DataDirectory,
    [string]$LauncherDirectory,
    [string]$StartMenuDirectory,
    [string]$NativeInstallDirectory,
    [string]$RegistryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$localInstaller = Join-Path $packageRoot 'scripts\install-local-tool.ps1'
$nativeInstaller = Join-Path $packageRoot 'scripts\install-native-host.ps1'
$hostExe = Join-Path $packageRoot 'dist\native-host\notion2dingding-host.exe'
$releaseConfigPath = Join-Path $packageRoot 'release-config.json'
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

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Label
    )
    $winget = Resolve-CommandPath -Name 'winget.exe'
    if (-not $winget) {
        throw "缺少 Windows Package Manager，无法自动安装 $Label。请先从 Microsoft Store 安装‘应用安装程序’。"
    }
    Write-Step "正在安装 $Label…"
    & $winget install --id $Id --exact --source winget --scope user --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "$Label 安装失败（winget exit=$LASTEXITCODE）。"
    }
    Refresh-ProcessPath
}

function Install-Dependencies {
    if (-not (Test-Node24)) {
        Install-WingetPackage -Id 'OpenJS.NodeJS' -Label 'Node.js 24+'
    }
    if (-not (Test-Pandoc3)) {
        Install-WingetPackage -Id 'JohnMacFarlane.Pandoc' -Label 'Pandoc 3+'
    }
    if (-not (Test-DwsVersion)) {
        $npm = Resolve-CommandPath -Name 'npm.cmd'
        if (-not $npm) { $npm = Resolve-CommandPath -Name 'npm' }
        if (-not $npm) {
            throw 'Node.js 已安装，但当前终端仍找不到 npm。请重新运行安装包。'
        }
        Write-Step '正在安装钉钉官方 dws 1.0.59…'
        & $npm install --global 'dingtalk-workspace-cli@1.0.59'
        if ($LASTEXITCODE -ne 0) {
            throw "dws 安装失败（npm exit=$LASTEXITCODE）。"
        }
        Refresh-ProcessPath
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
        Write-Step '正在卸载 Native Host…'
        $nativeArguments = [System.Collections.ArrayList]@('-Action', 'Uninstall')
        Add-OptionalArgument -Arguments $nativeArguments -Name '-InstallDirectory' -Value $NativeInstallDirectory
        Add-OptionalArgument -Arguments $nativeArguments -Name '-RegistryPath' -Value $RegistryPath
        if ($SkipRegistry) { [void]$nativeArguments.Add('-SkipRegistry') }
        $nativeResult = Invoke-Installer -Script $nativeInstaller -Arguments @($nativeArguments)

        Write-Step '正在卸载本地迁移核心…'
        $localArguments = [System.Collections.ArrayList]@('-Action', 'Uninstall')
        Add-OptionalArgument -Arguments $localArguments -Name '-InstallDirectory' -Value $LocalInstallDirectory
        Add-OptionalArgument -Arguments $localArguments -Name '-DataDirectory' -Value $DataDirectory
        Add-OptionalArgument -Arguments $localArguments -Name '-LauncherDirectory' -Value $LauncherDirectory
        Add-OptionalArgument -Arguments $localArguments -Name '-StartMenuDirectory' -Value $StartMenuDirectory
        $localResult = Invoke-Installer -Script $localInstaller -Arguments @($localArguments)

        [ordered]@{
            success = $true
            action = 'uninstall'
            localTool = $localResult
            nativeHost = $nativeResult
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
