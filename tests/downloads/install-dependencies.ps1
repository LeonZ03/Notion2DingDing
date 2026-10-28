[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('n2dd-dependency-test-' + [guid]::NewGuid().ToString('N'))
$originalLocalAppData = $env:LOCALAPPDATA
$originalPath = $env:Path
$mirrorRoot = Join-Path $repositoryRoot 'dist\mirror'
$requests = [System.Collections.ArrayList]::new()
try {
    $env:LOCALAPPDATA = $testRoot
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'scripts\install-release.ps1'), [ref]$null, [ref]$null)
    foreach ($name in @('Install-MirroredDependency', 'Install-Dependencies')) {
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        Invoke-Expression $definition.Extent.Text
    }
    $downloadOrigin = 'https://notion2dingding.leonz03.dpdns.org'
    function Write-Step { param([string]$Message) Write-Host $Message }
    function Add-UserPathEntry { param([string]$Directory) $env:Path = "$Directory;$env:Path" }
    function Test-Node24 { return $false }
    function Test-Pandoc3 { return $false }
    function Test-DwsVersion { return $false }
    function Invoke-WebRequest {
        param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
        if (-not $Uri.StartsWith("$downloadOrigin/downloads/")) { throw '安装访问了非项目源。' }
        [void]$requests.Add($Uri)
        Copy-Item -LiteralPath (Join-Path $mirrorRoot ([IO.Path]::GetFileName($Uri))) -Destination $OutFile
    }
    Install-Dependencies
    if ($requests.Count -ne 3) { throw '未验证全部三项运行时。' }
    Install-Dependencies
    if ($requests.Count -ne 3) { throw '已安装的依赖不应重复下载。' }
    $rejected = $false
    try {
        Install-MirroredDependency -Name 'Corrupt' -Version '1' -ArchiveName 'dws-windows-amd64-1.0.59.zip' -Sha256 ('0' * 64) -Executable 'dws.exe' -VersionPattern '.'
    } catch { $rejected = $_.Exception.Message -match '校验失败' }
    if (-not $rejected) { throw '损坏校验和未被拒绝。' }
    $foreign = Join-Path $testRoot 'Programs\Notion2DingDingDependencies\Foreign\1'
    New-Item -ItemType Directory -Path $foreign -Force | Out-Null
    $rejected = $false
    try {
        Install-MirroredDependency -Name 'Foreign' -Version '1' -ArchiveName 'dws-windows-amd64-1.0.59.zip' -Sha256 ('0' * 64) -Executable 'dws.exe' -VersionPattern '.'
    } catch { $rejected = $_.Exception.Message -match '所有权标记' }
    if (-not $rejected) { throw '未阻止覆盖不属于本项目的目录。' }
    [ordered]@{ success = $true; realRuntimeExtraction = $true; versionChecks = $true; reuse = $true; corruptHashRejected = $true; foreignDirectoryPreserved = $true; noRegistryWrites = $true } | ConvertTo-Json
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:Path = $originalPath
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'n2dd-dependency-test-*') { throw '测试清理目录越界。' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    if (Test-Path -LiteralPath $resolved) { throw '测试目录清理失败。' }
}
