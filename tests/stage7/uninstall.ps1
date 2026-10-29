[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$testRoot=Join-Path $env:TEMP ('notion2dingding-uninstall-test-' + [guid]::NewGuid().ToString('N'))
$registryRoot='HKCU:\Software\Notion2DingDing.Tests\' + [guid]::NewGuid().ToString('N')
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Assert-Test([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Get-TestHash([string]$Path) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($algorithm.ComputeHash([IO.File]::ReadAllBytes($Path))) } finally { $algorithm.Dispose() }
}
function Invoke-TestInstaller([string[]]$Extra) {
    $installer=Join-Path $repo 'scripts\install-release.ps1'
    $installedUninstaller=Join-Path $script:local 'maintenance\scripts\install-release.ps1'
    if ($Extra -contains 'Uninstall' -and (Test-Path -LiteralPath $installedUninstaller)) { $installer=$installedUninstaller }
    $result=& $ps -NoProfile -ExecutionPolicy Bypass -File $installer @script:common @Extra 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw $result }
    return ($result | ConvertFrom-Json)
}
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $local=Join-Path $testRoot 'Core'
    $native=Join-Path $testRoot 'Host'
    $data=Join-Path $testRoot 'Data'
    $start=Join-Path $testRoot 'StartMenu'
    $deps=Join-Path $testRoot 'Notion2DingDingDependencies'
    $uninstallKey="$registryRoot\Uninstall"
    $script:common=@('-Quiet','-SkipDependencyInstall','-SkipDependencyCheck','-SkipUserPathUpdate','-LocalInstallDirectory',$local,'-NativeInstallDirectory',$native,'-DataDirectory',$data,'-LauncherDirectory',(Join-Path $testRoot 'Launcher'),'-StartMenuDirectory',$start,'-DependencyDirectory',$deps,'-RegistryPath',"$registryRoot\Native",'-UninstallRegistryPath',$uninstallKey)
    $source=Join-Path $testRoot 'source.zip'
    [IO.File]::WriteAllText($source,'user-owned-source')
    $sourceHash=Get-TestHash $source
    $null=Invoke-TestInstaller @()
    Assert-Test (Test-Path -LiteralPath (Join-Path $local 'maintenance\scripts\uninstall-notion2dingding.ps1')) '安装版缺少独立卸载器。'
    Assert-Test (Test-Path -LiteralPath (Join-Path $start 'Notion2DingDing\卸载 Notion2DingDing.lnk')) '缺少开始菜单卸载入口。'
    $entry=Get-ItemProperty -LiteralPath $uninstallKey
    Assert-Test ($entry.DisplayName -eq 'Notion2DingDing 本地助手' -and $entry.UninstallString.Contains('launch-uninstall.vbs')) 'Windows 应用卸载注册无效。'
    $null=Invoke-TestInstaller @()
    Assert-Test (Test-Path -LiteralPath $uninstallKey) '覆盖升级丢失卸载注册项。'
    foreach ($name in @('Node','Pandoc','Dws')) {
        $versionRoot=Join-Path $deps "$name\1"
        New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
        @{owner='Notion2DingDing';version='1';sha256=('a'*64)} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $versionRoot '.n2dd-dependency.json') -Encoding UTF8
        [IO.File]::WriteAllText((Join-Path $versionRoot 'payload'),'managed')
    }
    $foreign=Join-Path $deps 'Node\foreign'
    New-Item -ItemType Directory -Path $foreign -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $foreign 'keep'),'shared')
    $logoutLog=Join-Path $testRoot 'logout-called'
    $fakeDws=Join-Path $testRoot 'dws.cmd'
    [IO.File]::WriteAllText($fakeDws, "@echo off`r`nif `"%~1`"==`"--version`" (`r`necho dws v1.0.59`r`nexit /b 0`r`n)`r`necho called>`"$logoutLog`"`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    $result=Invoke-TestInstaller @('-Action','Uninstall','-DwsCommandPath',$fakeDws)
    Assert-Test (-not $result.dingtalkLoginCleared -and -not (Test-Path -LiteralPath $logoutLog)) '默认卸载不应退出钉钉登录。'
    Assert-Test ($result.dependencies.removedCount -eq 3) '未清理三类专属依赖。'
    foreach ($path in @($local,$native,$data,$uninstallKey,(Join-Path $start 'Notion2DingDing'))) { Assert-Test (-not (Test-Path -LiteralPath $path)) "卸载残留：$path" }
    Assert-Test (Test-Path -LiteralPath (Join-Path $foreign 'keep')) '误删外来依赖目录。'
    Assert-Test ((Get-TestHash $source) -eq $sourceHash) '误改源文件。'
    $null=Invoke-TestInstaller @()
    $result=Invoke-TestInstaller @('-Action','Uninstall','-RemoveDingtalkLogin','-DwsCommandPath',$fakeDws)
    Assert-Test ($result.dingtalkLoginCleared -and (Test-Path -LiteralPath $logoutLog)) '显式清除登录状态未调用 dws。'
    # 外来 Windows 卸载项必须在程序删除前被拒绝。
    $null=Invoke-TestInstaller @()
    Set-ItemProperty -LiteralPath $uninstallKey -Name N2DDOwnershipId -Value 'foreign'
    $rejected=$false
    try { $null=Invoke-TestInstaller @('-Action','Uninstall') } catch { $rejected=$_.Exception.Message -match '不属于本项目' }
    Assert-Test ($rejected -and (Test-Path -LiteralPath $local)) '未保护外来卸载注册项。'
    Set-ItemProperty -LiteralPath $uninstallKey -Name N2DDOwnershipId -Value 'com.leonz03.notion2dingding.uninstaller'
    $null=Invoke-TestInstaller @('-Action','Uninstall')
    [ordered]@{success=$true;windowsUninstallEntry=$true;startMenu=$true;upgrade=$true;managedDependenciesRemoved=$true;foreignDependenciesPreserved=$true;loginOptIn=$true;foreignRegistryRejected=$true;sourcePreserved=$true} | ConvertTo-Json
} finally {
    $full=[IO.Path]::GetFullPath($testRoot)
    $parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if (-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'notion2dingding-uninstall-test-*') { throw '测试清理路径越界。' }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
    if (-not $registryRoot.StartsWith('HKCU:\Software\Notion2DingDing.Tests\')) { throw '测试注册路径越界。' }
    if (Test-Path -LiteralPath $registryRoot) { Remove-Item -LiteralPath $registryRoot -Recurse -Force }
}
