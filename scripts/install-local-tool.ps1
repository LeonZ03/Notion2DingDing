[CmdletBinding()]
param(
    [ValidateSet('Install', 'Upgrade', 'Uninstall')]
    [string]$Action = 'Install',

    [string]$InstallDirectory,

    [string]$DataDirectory,

    [string]$LauncherDirectory,

    [string]$StartMenuDirectory,

    [switch]$SkipDependencyCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ownershipId = 'com.leonz03.notion2dingding.cli'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA)
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'

if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
    $InstallDirectory = Join-Path $localAppData 'Programs\Notion2DingDing'
}
if ([string]::IsNullOrWhiteSpace($DataDirectory)) {
    $DataDirectory = Join-Path $localAppData 'Notion2DingDing'
}
if ([string]::IsNullOrWhiteSpace($LauncherDirectory)) {
    $LauncherDirectory = Join-Path $localAppData 'Microsoft\WindowsApps'
}
if ([string]::IsNullOrWhiteSpace($StartMenuDirectory)) {
    $StartMenuDirectory = Join-Path ([IO.Path]::GetFullPath($env:APPDATA)) 'Microsoft\Windows\Start Menu\Programs'
}

$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$DataDirectory = [IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
$LauncherDirectory = [IO.Path]::GetFullPath($LauncherDirectory).TrimEnd('\')
$StartMenuDirectory = [IO.Path]::GetFullPath($StartMenuDirectory).TrimEnd('\')
$installMarkerPath = Join-Path $InstallDirectory '.n2dd-install.json'
$dataMarkerPath = Join-Path $DataDirectory '.n2dd-data.json'
$launcherPath = Join-Path $LauncherDirectory 'n2dd.cmd'
$shortcutDirectory = Join-Path $StartMenuDirectory 'Notion2DingDing'
$shortcutMarkerPath = Join-Path $shortcutDirectory '.n2dd-shortcut.json'
$shortcutPath = Join-Path $shortcutDirectory 'Notion2DingDing.lnk'

function Assert-NonBroadPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($resolved).TrimEnd('\')
    if ($resolved.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label 不能是磁盘根目录：$resolved"
    }
    if ($resolved.Length -le ($root.Length + 3)) {
        throw "$Label 过于宽泛，拒绝操作：$resolved"
    }
}

function Read-OwnershipMarker {
    param(
        [Parameter(Mandatory)][string]$MarkerPath,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
        throw "$Label 缺少所有权标记，拒绝修改或删除：$MarkerPath"
    }
    try {
        $marker = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "$Label 所有权标记损坏，拒绝修改或删除：$MarkerPath"
    }
    if ($marker.ownershipId -ne $ownershipId) {
        throw "$Label 所有权标记不匹配，拒绝修改或删除：$MarkerPath"
    }
    return $marker
}

function Remove-OwnedDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$MarkerPath,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        return
    }
    [void](Read-OwnershipMarker -MarkerPath $MarkerPath -Label $Label)
    Assert-NonBroadPath -Path $Directory -Label $Label
    Remove-Item -LiteralPath $Directory -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $Directory) {
        throw "$Label 未能永久删除：$Directory"
    }
}

function Write-Utf8Json {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $temporary = "$Path.$PID.tmp"
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($Value | ConvertTo-Json -Depth 8),
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
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

function Test-ManagedLauncher {
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        return $false
    }
    $firstLine = Get-Content -LiteralPath $launcherPath -TotalCount 1
    return $firstLine -eq '@rem Notion2DingDing managed launcher'
}

function Remove-GeneratedDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$ExpectedPrefix
    )

    if (-not $Directory) { return }
    $resolved = [IO.Path]::GetFullPath($Directory)
    if (-not $resolved.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理未通过前缀校验的目录：$resolved"
    }
    if (Test-Path -LiteralPath $resolved) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    }
}

Assert-NonBroadPath -Path $InstallDirectory -Label '程序目录'
Assert-NonBroadPath -Path $DataDirectory -Label '数据目录'
Assert-NonBroadPath -Path $LauncherDirectory -Label '命令目录'
Assert-NonBroadPath -Path $shortcutDirectory -Label '开始菜单快捷方式目录'

try {
    if ($Action -eq 'Uninstall') {
        if (Test-Path -LiteralPath $launcherPath) {
            if (-not (Test-ManagedLauncher)) {
                throw "n2dd.cmd 不是本项目管理的启动器，拒绝删除：$launcherPath"
            }
        }
        if (Test-Path -LiteralPath $InstallDirectory) {
            [void](Read-OwnershipMarker -MarkerPath $installMarkerPath -Label '程序目录')
        }
        if (Test-Path -LiteralPath $DataDirectory) {
            [void](Read-OwnershipMarker -MarkerPath $dataMarkerPath -Label '数据目录')
        }
        if (Test-Path -LiteralPath $shortcutDirectory) {
            [void](Read-OwnershipMarker -MarkerPath $shortcutMarkerPath -Label '开始菜单快捷方式目录')
        }

        Remove-Item -LiteralPath $launcherPath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $launcherPath) {
            throw "启动器未能永久删除：$launcherPath"
        }
        Remove-OwnedDirectory -Directory $shortcutDirectory -MarkerPath $shortcutMarkerPath -Label '开始菜单快捷方式目录'
        Remove-OwnedDirectory -Directory $InstallDirectory -MarkerPath $installMarkerPath -Label '程序目录'
        Remove-OwnedDirectory -Directory $DataDirectory -MarkerPath $dataMarkerPath -Label '数据目录'

        [ordered]@{
            success = $true
            action = 'uninstall'
            installDirectoryRemoved = -not (Test-Path -LiteralPath $InstallDirectory)
            dataDirectoryRemoved = -not (Test-Path -LiteralPath $DataDirectory)
            launcherRemoved = -not (Test-Path -LiteralPath $launcherPath)
            shortcutRemoved = -not (Test-Path -LiteralPath $shortcutDirectory)
        } | ConvertTo-Json -Depth 5
        exit 0
    }

    $packagePath = Join-Path $repositoryRoot 'package.json'
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw "缺少 package.json：$packagePath"
    }
    $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
    $version = [string]$package.version
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw 'package.json 缺少 version。'
    }

    $existingMarker = $null
    if (Test-Path -LiteralPath $InstallDirectory) {
        $existingMarker = Read-OwnershipMarker -MarkerPath $installMarkerPath -Label '程序目录'
    }
    if ($Action -eq 'Install' -and $existingMarker) {
        throw "已经安装版本 $($existingMarker.version)。请使用 -Action Upgrade。"
    }
    if ($Action -eq 'Upgrade' -and -not $existingMarker) {
        throw '尚未安装 Notion2DingDing，不能升级；请先使用 -Action Install。'
    }

    if ((Test-Path -LiteralPath $launcherPath) -and -not (Test-ManagedLauncher)) {
        throw "命令目录已存在非本项目管理的 n2dd.cmd，拒绝覆盖：$launcherPath"
    }
    if (Test-Path -LiteralPath $shortcutDirectory) {
        [void](Read-OwnershipMarker -MarkerPath $shortcutMarkerPath -Label '开始菜单快捷方式目录')
    }

    $dataDirectoryExisted = Test-Path -LiteralPath $DataDirectory
    $dataMarkerExisted = Test-Path -LiteralPath $dataMarkerPath -PathType Leaf
    $shortcutDirectoryExisted = Test-Path -LiteralPath $shortcutDirectory
    if ($dataDirectoryExisted -and -not (Test-Path -LiteralPath $dataMarkerPath -PathType Leaf)) {
        $allowedNames = @('state', 'config.json')
        $unexpected = @(
            Get-ChildItem -LiteralPath $DataDirectory -Force |
                Where-Object { $_.Name -notin $allowedNames }
        )
        if ($unexpected.Count -gt 0) {
            throw "数据目录包含非本项目已知内容，拒绝接管：$($unexpected.Name -join ', ')"
        }
    }
    elseif ($dataDirectoryExisted) {
        [void](Read-OwnershipMarker -MarkerPath $dataMarkerPath -Label '数据目录')
    }

    $nonce = "$PID-$([Guid]::NewGuid().ToString('N'))"
    $stagingDirectory = "$InstallDirectory.staging-$nonce"
    $backupDirectory = "$InstallDirectory.backup-$nonce"
    $generatedPrefix = "$InstallDirectory."
    $launcherTemporary = Join-Path $LauncherDirectory "n2dd.cmd.$nonce.tmp"
    $shortcutTemporary = Join-Path $shortcutDirectory "Notion2DingDing.$nonce.tmp.lnk"
    $programMoved = $false
    $backupCreated = $false
    try {
        [IO.Directory]::CreateDirectory((Join-Path $stagingDirectory 'runtime\scripts')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $stagingDirectory 'cli')) | Out-Null

        $payload = @(
            @{ Source = 'scripts\migrate-notion-to-dingtalk.mjs'; Destination = 'runtime\scripts\migrate-notion-to-dingtalk.mjs' },
            @{ Source = 'scripts\convert-notion-export.ps1'; Destination = 'runtime\scripts\convert-notion-export.ps1' },
            @{ Source = 'scripts\notion-html-columns.lua'; Destination = 'runtime\scripts\notion-html-columns.lua' },
            @{ Source = 'scripts\normalize-notion-docx-layout.ps1'; Destination = 'runtime\scripts\normalize-notion-docx-layout.ps1' },
            @{ Source = 'scripts\test-docx-assets.ps1'; Destination = 'runtime\scripts\test-docx-assets.ps1' },
            @{ Source = 'scripts\notion2dingding.ps1'; Destination = 'cli\notion2dingding.ps1' },
            @{ Source = 'scripts\diagnose-local-tool.ps1'; Destination = 'cli\diagnose-local-tool.ps1' },
            @{ Source = 'scripts\notion2dingding-gui.ps1'; Destination = 'cli\notion2dingding-gui.ps1' },
            @{ Source = 'scripts\launch-notion2dingding-gui.vbs'; Destination = 'cli\launch-notion2dingding-gui.vbs' }
        )
        $installedFiles = @()
        foreach ($item in $payload) {
            $sourcePath = Join-Path $repositoryRoot $item.Source
            $destinationPath = Join-Path $stagingDirectory $item.Destination
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "安装源文件不存在：$sourcePath"
            }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath)) | Out-Null
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
            $installedFiles += [ordered]@{
                path = $item.Destination.Replace('\', '/')
                sha256 = Get-FileSha256 -Path $destinationPath
            }
        }

        $installedAt = [DateTime]::UtcNow.ToString('o')
        if ($existingMarker -and $existingMarker.installedAt) {
            $installedAt = [string]$existingMarker.installedAt
        }
        $programMarker = [ordered]@{
            ownershipId = $ownershipId
            markerVersion = 1
            version = $version
            installedAt = $installedAt
            updatedAt = [DateTime]::UtcNow.ToString('o')
            dataDirectory = $DataDirectory
            launcherPath = $launcherPath
            shortcutPath = $shortcutPath
            files = $installedFiles
        }
        Write-Utf8Json -Path (Join-Path $stagingDirectory '.n2dd-install.json') -Value $programMarker

        if ($existingMarker) {
            Move-Item -LiteralPath $InstallDirectory -Destination $backupDirectory
            $backupCreated = $true
        }
        Move-Item -LiteralPath $stagingDirectory -Destination $InstallDirectory
        $programMoved = $true

        [IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
        $dataCreatedAt = [DateTime]::UtcNow.ToString('o')
        if (Test-Path -LiteralPath $dataMarkerPath -PathType Leaf) {
            $existingDataMarker = Get-Content -LiteralPath $dataMarkerPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$existingDataMarker.createdAt)) {
                $dataCreatedAt = [string]$existingDataMarker.createdAt
            }
        }
        $dataMarker = [ordered]@{
            ownershipId = $ownershipId
            markerVersion = 1
            createdAt = $dataCreatedAt
            updatedAt = [DateTime]::UtcNow.ToString('o')
        }
        Write-Utf8Json -Path $dataMarkerPath -Value $dataMarker

        [IO.Directory]::CreateDirectory($LauncherDirectory) | Out-Null
        $cliPath = Join-Path $InstallDirectory 'cli\notion2dingding.ps1'
        $launcherContent = @(
            '@rem Notion2DingDing managed launcher',
            '@echo off',
            ('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "' + $cliPath + '" %*'),
            'exit /b %ERRORLEVEL%'
        ) -join "`r`n"
        [IO.File]::WriteAllText($launcherTemporary, $launcherContent, [Text.ASCIIEncoding]::new())
        Move-Item -LiteralPath $launcherTemporary -Destination $launcherPath -Force

        [IO.Directory]::CreateDirectory($shortcutDirectory) | Out-Null
        $shortcutCreatedAt = [DateTime]::UtcNow.ToString('o')
        if (Test-Path -LiteralPath $shortcutMarkerPath -PathType Leaf) {
            $existingShortcutMarker = Get-Content -LiteralPath $shortcutMarkerPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$existingShortcutMarker.createdAt)) {
                $shortcutCreatedAt = [string]$existingShortcutMarker.createdAt
            }
        }
        Write-Utf8Json -Path $shortcutMarkerPath -Value ([ordered]@{
            ownershipId = $ownershipId
            markerVersion = 1
            createdAt = $shortcutCreatedAt
            updatedAt = [DateTime]::UtcNow.ToString('o')
            shortcutPath = $shortcutPath
        })
        $guiLauncher = Join-Path $InstallDirectory 'cli\launch-notion2dingding-gui.vbs'
        $shell = $null
        $shortcut = $null
        $shell = New-Object -ComObject WScript.Shell
        try {
            $shortcut = $shell.CreateShortcut($shortcutTemporary)
            $shortcut.TargetPath = $wscriptPath
            $shortcut.Arguments = '"' + $guiLauncher + '"'
            $shortcut.WorkingDirectory = $DataDirectory
            $shortcut.Description = '把 Notion 导出包转换为钉钉文档'
            $shortcut.Save()
        }
        finally {
            if ($shortcut) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null }
            if ($shell) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
        }
        Move-Item -LiteralPath $shortcutTemporary -Destination $shortcutPath -Force
        if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
            throw "开始菜单快捷方式未能创建：$shortcutPath"
        }

        $diagnostics = $null
        if (-not $SkipDependencyCheck) {
            try {
                $doctorScript = Join-Path $InstallDirectory 'cli\diagnose-local-tool.ps1'
                $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $doctorOutput = & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $doctorScript -DataDirectory $DataDirectory -NoExitCode | Out-String
                $diagnostics = $doctorOutput | ConvertFrom-Json
            }
            catch {
                $diagnostics = [ordered]@{
                    success = $false
                    ready = $false
                    checks = @()
                    fixes = @('n2dd doctor')
                    error = $_.Exception.Message
                }
            }
        }

        if ($backupCreated) {
            Remove-GeneratedDirectory -Directory $backupDirectory -ExpectedPrefix $generatedPrefix
            $backupCreated = $false
        }

        [ordered]@{
            success = $true
            action = $Action.ToLowerInvariant()
            version = $version
            installDirectory = $InstallDirectory
            dataDirectory = $DataDirectory
            launcherPath = $launcherPath
            shortcutPath = $shortcutPath
            ready = if ($null -eq $diagnostics) { $null } else { [bool]$diagnostics.ready }
            diagnostics = $diagnostics
            next = '从 Windows 开始菜单打开 Notion2DingDing，在同一个界面完成检查、配置和转换。'
        } | ConvertTo-Json -Depth 8
    }
    catch {
        if ($programMoved -and (Test-Path -LiteralPath $InstallDirectory)) {
            $newMarker = Join-Path $InstallDirectory '.n2dd-install.json'
            if (Test-Path -LiteralPath $newMarker) {
                Remove-OwnedDirectory -Directory $InstallDirectory -MarkerPath $newMarker -Label '未完成安装目录'
            }
        }
        if ($backupCreated -and (Test-Path -LiteralPath $backupDirectory)) {
            Move-Item -LiteralPath $backupDirectory -Destination $InstallDirectory
            $backupCreated = $false
        }
        if (-not $dataDirectoryExisted -and (Test-Path -LiteralPath $DataDirectory)) {
            Remove-OwnedDirectory -Directory $DataDirectory -MarkerPath $dataMarkerPath -Label '未完成安装数据目录'
        }
        elseif (-not $dataMarkerExisted -and (Test-Path -LiteralPath $dataMarkerPath)) {
            Remove-Item -LiteralPath $dataMarkerPath -Force -ErrorAction SilentlyContinue
        }
        if (-not $shortcutDirectoryExisted -and (Test-Path -LiteralPath $shortcutDirectory)) {
            Remove-OwnedDirectory -Directory $shortcutDirectory -MarkerPath $shortcutMarkerPath -Label '未完成安装快捷方式目录'
        }
        throw
    }
    finally {
        Remove-Item -LiteralPath $launcherTemporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $shortcutTemporary -Force -ErrorAction SilentlyContinue
        Remove-GeneratedDirectory -Directory $stagingDirectory -ExpectedPrefix $generatedPrefix
    }
}
catch {
    [ordered]@{
        success = $false
        action = $Action.ToLowerInvariant()
        error = [ordered]@{
            code = 'LOCAL_TOOL_MANAGEMENT_FAILED'
            message = $_.Exception.Message
        }
    } | ConvertTo-Json -Depth 5
    exit 1
}
