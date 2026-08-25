[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$installer = Join-Path $repoRoot 'scripts\install-local-tool.ps1'
$fixture = Join-Path $repoRoot 'tests\fixtures\notion-export'
$fakeDws = Join-Path $repoRoot 'tests\stage2\fake-dws.mjs'
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$runRoot = Join-Path $temporaryBase ('notion2dingding-stage4-' + [Guid]::NewGuid().ToString('N'))
$installDirectory = Join-Path $runRoot 'user\Programs\Notion2DingDing'
$dataDirectory = Join-Path $runRoot 'user\AppData\Local\Notion2DingDing'
$launcherDirectory = Join-Path $runRoot 'user\AppData\Local\Microsoft\WindowsApps'
$launcherPath = Join-Path $launcherDirectory 'n2dd.cmd'
$foreignPath = Join-Path $runRoot 'foreign.keep'
$dwsLog = Join-Path $runRoot 'fake-dws-calls.jsonl'
$fixtureFile = (Get-ChildItem -LiteralPath $fixture -File | Select-Object -First 1).FullName

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
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    [IO.File]::WriteAllText($foreignPath, '不属于 Notion2DingDing 的文件', [Text.UTF8Encoding]::new($false))

    $install = Invoke-JsonScript -Script $installer -Arguments @(
        '-Action', 'Install',
        '-InstallDirectory', $installDirectory,
        '-DataDirectory', $dataDirectory,
        '-LauncherDirectory', $launcherDirectory,
        '-SkipDependencyCheck'
    )
    Assert-True -Condition ($install.success -eq $true) -Message '首次安装必须成功。'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $installDirectory '.n2dd-install.json')) -Message '安装所有权标记不存在。'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $dataDirectory '.n2dd-data.json')) -Message '数据所有权标记不存在。'
    Assert-True -Condition (Test-Path -LiteralPath $launcherPath) -Message 'n2dd 启动器不存在。'

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
        '-DwsCommand', $fakeDws,
        '-NoExitCode'
    )
    Assert-True -Condition ($readyDoctor.ready -eq $true) -Message '依赖和登录均有效时 doctor 应报告就绪。'

    $configured = Invoke-LauncherJson -Arguments @(
        'config', '--folder', 'fake-stage4-folder', '--profile', 'isolated-profile'
    )
    Assert-True -Condition ($configured.configured -eq $true) -Message '默认目标配置失败。'

    $env:N2DD_FAKE_IMAGE_COUNT = '2'
    $migration = Invoke-LauncherJson -Arguments @(
        'migrate',
        '--input', $fixture,
        '--name', '阶段 4 隔离安装验收',
        '--dws-path', $fakeDws,
        '--force'
    )
    Assert-True -Condition ($migration.success -eq $true) -Message '安装后的 n2dd 未能完成代表性迁移。'
    Assert-True -Condition ($migration.remote.documentUrl -eq 'https://alidocs.dingtalk.com/i/nodes/fake-stage2-node') -Message '安装后的迁移未返回预期文档 URL。'
    Assert-True -Condition ($migration.local.docx.permanentlyDeleted -eq $true) -Message '安装后的迁移未确认永久删除 DOCX。'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $installDirectory 'runtime\.n2dd-tmp'))) -Message '安装后的迁移残留临时任务目录。'

    $calls = @(
        Get-Content -LiteralPath $dwsLog |
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
        '-SkipDependencyCheck'
    )
    Assert-True -Condition ($upgrade.success -eq $true) -Message '升级必须成功。'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $installDirectory 'stale-owned-file.tmp'))) -Message '升级没有替换旧程序目录。'
    $configAfterUpgrade = Invoke-LauncherJson -Arguments @('config', '--show')
    Assert-True -Condition ($configAfterUpgrade.folder -eq 'fake-stage4-folder') -Message '升级后默认目标配置丢失。'

    $uninstall = Invoke-JsonScript -Script $installer -Arguments @(
        '-Action', 'Uninstall',
        '-InstallDirectory', $installDirectory,
        '-DataDirectory', $dataDirectory,
        '-LauncherDirectory', $launcherDirectory
    )
    Assert-True -Condition ($uninstall.success -eq $true) -Message '卸载必须成功。'
    Assert-True -Condition (-not (Test-Path -LiteralPath $installDirectory)) -Message '卸载后程序目录仍存在。'
    Assert-True -Condition (-not (Test-Path -LiteralPath $dataDirectory)) -Message '卸载后数据目录仍存在。'
    Assert-True -Condition (-not (Test-Path -LiteralPath $launcherPath)) -Message '卸载后启动器仍存在。'
    Assert-True -Condition (Test-Path -LiteralPath $foreignPath) -Message '卸载误删了项目范围外文件。'

    [IO.Directory]::CreateDirectory($launcherDirectory) | Out-Null
    [IO.File]::WriteAllText($launcherPath, '@echo off', [Text.ASCIIEncoding]::new())
    $refused = Invoke-JsonScript -Script $installer -Arguments @(
        '-Action', 'Uninstall',
        '-InstallDirectory', $installDirectory,
        '-DataDirectory', $dataDirectory,
        '-LauncherDirectory', $launcherDirectory
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
        configure = $true
        migrate = $true
        upgrade = $true
        uninstall = $true
        foreignFilesPreserved = $true
        sourceInputPreserved = $true
    } | ConvertTo-Json
}
finally {
    Remove-Item Env:N2DD_FAKE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:N2DD_FAKE_IMAGE_COUNT -ErrorAction SilentlyContinue
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
