[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CliArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ownershipId = 'com.leonz03.notion2dingding.cli'
$programDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $programDirectory '.n2dd-install.json'

function Write-Result {
    param([Parameter(Mandatory)]$Value)
    $Value | ConvertTo-Json -Depth 6
}

function Write-Help {
    @'
Notion2DingDing 本地命令

用法：
  n2dd config --folder <nodeId> [--profile <名称>]
  n2dd config --workspace <workspaceId> [--profile <名称>]
  n2dd config --show | --clear
  n2dd doctor
  n2dd migrate --input <Notion ZIP或目录> [迁移选项]
  n2dd --input <Notion ZIP或目录> [迁移选项]
  n2dd version

保存默认目标后，日常迁移无需重复填写 --folder 或 --workspace。
'@ | Write-Output
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "安装状态不存在：$manifestPath。请重新运行安装脚本。"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.ownershipId -ne $ownershipId) {
    throw '安装目录所有权标记不匹配，拒绝继续。'
}
$dataDirectory = [IO.Path]::GetFullPath([string]$manifest.dataDirectory)
$configPath = Join-Path $dataDirectory 'config.json'

if (-not $CliArguments -or $CliArguments.Count -eq 0) {
    Write-Help
    exit 0
}

$command = $CliArguments[0].ToLowerInvariant()
if ($command -in @('help', '-h', '--help')) {
    Write-Help
    exit 0
}

if ($command -eq 'version') {
    Write-Result -Value ([ordered]@{
        success = $true
        version = [string]$manifest.version
        installDirectory = $programDirectory
    })
    exit 0
}

if ($command -eq 'doctor') {
    $doctorScript = Join-Path $PSScriptRoot 'diagnose-local-tool.ps1'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $doctorArguments = @()
    if ($CliArguments.Count -gt 1) {
        $doctorArguments = @($CliArguments[1..($CliArguments.Count - 1)])
    }
    & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $doctorScript -DataDirectory $dataDirectory @doctorArguments
    exit $LASTEXITCODE
}

if ($command -eq 'config') {
    $configArguments = @()
    if ($CliArguments.Count -gt 1) {
        $configArguments = @($CliArguments[1..($CliArguments.Count - 1)])
    }

    if ($configArguments -contains '--show') {
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            Write-Result -Value ([ordered]@{ success = $true; configured = $false })
            exit 0
        }
        $current = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        Write-Result -Value ([ordered]@{
            success = $true
            configured = $true
            folder = [string]$current.folder
            workspace = [string]$current.workspace
            profile = [string]$current.profile
        })
        exit 0
    }

    if ($configArguments -contains '--clear') {
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $configPath) {
            throw "配置未能永久删除：$configPath"
        }
        Write-Result -Value ([ordered]@{ success = $true; configured = $false; cleared = $true })
        exit 0
    }

    $folder = ''
    $workspace = ''
    $profile = ''
    for ($index = 0; $index -lt $configArguments.Count; $index += 1) {
        $argument = $configArguments[$index]
        if ($argument -notin @('--folder', '--workspace', '--profile')) {
            throw "未知配置参数：$argument"
        }
        if ($index + 1 -ge $configArguments.Count) {
            throw "配置参数缺少值：$argument"
        }
        $value = $configArguments[$index + 1]
        if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('--')) {
            throw "配置参数缺少值：$argument"
        }
        if ($argument -eq '--folder') { $folder = $value }
        if ($argument -eq '--workspace') { $workspace = $value }
        if ($argument -eq '--profile') { $profile = $value }
        $index += 1
    }

    if ((-not [string]::IsNullOrWhiteSpace($folder)) -eq (-not [string]::IsNullOrWhiteSpace($workspace))) {
        throw '配置必须且只能提供 --folder 或 --workspace 其中一个。'
    }

    [IO.Directory]::CreateDirectory($dataDirectory) | Out-Null
    $temporaryConfig = "$configPath.$PID.tmp"
    $config = [ordered]@{
        version = 1
        folder = $folder
        workspace = $workspace
        profile = $profile
        updatedAt = [DateTime]::UtcNow.ToString('o')
    }
    try {
        [IO.File]::WriteAllText(
            $temporaryConfig,
            ($config | ConvertTo-Json -Depth 4),
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryConfig -Force -ErrorAction SilentlyContinue
    }

    Write-Result -Value ([ordered]@{
        success = $true
        configured = $true
        folder = $folder
        workspace = $workspace
        profile = $profile
    })
    exit 0
}

$migrationArguments = @($CliArguments)
if ($command -eq 'migrate') {
    if ($CliArguments.Count -gt 1) {
        $migrationArguments = @($CliArguments[1..($CliArguments.Count - 1)])
    }
    else {
        $migrationArguments = @()
    }
}
elseif (-not $CliArguments[0].StartsWith('--')) {
    throw "未知命令：$($CliArguments[0])。请运行 n2dd --help。"
}

$hasFolder = $migrationArguments -contains '--folder'
$hasWorkspace = $migrationArguments -contains '--workspace'
$hasProfile = $migrationArguments -contains '--profile'
if (-not $hasFolder -and -not $hasWorkspace) {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw '尚未配置默认钉钉目标。请先运行 n2dd config --folder <nodeId>，或在迁移命令中显式提供目标。'
    }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $configuredFolder = [string]$config.folder
    $configuredWorkspace = [string]$config.workspace
    if ((-not [string]::IsNullOrWhiteSpace($configuredFolder)) -eq (-not [string]::IsNullOrWhiteSpace($configuredWorkspace))) {
        throw '默认目标配置无效。请重新运行 n2dd config。'
    }
    if ($configuredFolder) {
        $migrationArguments += @('--folder', $configuredFolder)
    }
    else {
        $migrationArguments += @('--workspace', $configuredWorkspace)
    }
    if (-not $hasProfile -and -not [string]::IsNullOrWhiteSpace([string]$config.profile)) {
        $migrationArguments += @('--profile', [string]$config.profile)
    }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    throw '未找到 Node.js 24+。请运行 n2dd doctor 查看安装指引。'
}
$nodeVersion = & $node.Source --version
$nodeMatch = [regex]::Match([string]$nodeVersion, 'v?(\d+)')
if (-not $nodeMatch.Success -or [int]$nodeMatch.Groups[1].Value -lt 24) {
    throw "Node.js 版本不满足要求：$nodeVersion。请安装 Node.js 24+。"
}

$migrationScript = Join-Path $programDirectory 'runtime\scripts\migrate-notion-to-dingtalk.mjs'
if (-not (Test-Path -LiteralPath $migrationScript -PathType Leaf)) {
    throw "迁移核心不存在：$migrationScript。请重新安装或升级。"
}

$previousStateDirectory = $env:N2DD_STATE_DIRECTORY
$previousTemporaryDirectory = $env:N2DD_TEMP_DIRECTORY
$env:N2DD_STATE_DIRECTORY = Join-Path $dataDirectory 'state\migrations'
$env:N2DD_TEMP_DIRECTORY = Join-Path $programDirectory 'runtime\.n2dd-tmp'
try {
    & $node.Source $migrationScript @migrationArguments
    $migrationExitCode = $LASTEXITCODE
}
finally {
    if ($null -eq $previousStateDirectory) {
        Remove-Item Env:N2DD_STATE_DIRECTORY -ErrorAction SilentlyContinue
    }
    else {
        $env:N2DD_STATE_DIRECTORY = $previousStateDirectory
    }
    if ($null -eq $previousTemporaryDirectory) {
        Remove-Item Env:N2DD_TEMP_DIRECTORY -ErrorAction SilentlyContinue
    }
    else {
        $env:N2DD_TEMP_DIRECTORY = $previousTemporaryDirectory
    }
}
exit $migrationExitCode
