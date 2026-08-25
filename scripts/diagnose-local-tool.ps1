[CmdletBinding()]
param(
    [string]$DataDirectory,

    [string]$NodeCommand = 'node',

    [string]$PandocCommand = 'pandoc.exe',

    [string]$DwsCommand = 'dws',

    [switch]$NoExitCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ToolCommand {
    param([Parameter(Mandatory)][string]$Command)

    if (
        [IO.Path]::IsPathRooted($Command) -or
        $Command.Contains('\') -or
        $Command.Contains('/')
    ) {
        if (Test-Path -LiteralPath $Command -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Command).Path
        }
        return $null
    }

    $resolved = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $resolved) {
        return $null
    }
    if ($resolved.Source) {
        return $resolved.Source
    }
    return $resolved.Path
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$CommandPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$NodePath
    )

    $extension = [IO.Path]::GetExtension($CommandPath).ToLowerInvariant()
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($extension -eq '.ps1') {
        $output = & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $CommandPath @Arguments 2>&1 | Out-String
    }
    elseif ($extension -in @('.js', '.mjs', '.cjs')) {
        if (-not $NodePath) {
            return [pscustomobject]@{ ExitCode = 1; Output = '缺少 Node.js，无法运行 JavaScript 形式的 dws。' }
        }
        $output = & $NodePath $CommandPath @Arguments 2>&1 | Out-String
    }
    else {
        $output = & $CommandPath @Arguments 2>&1 | Out-String
    }

    return [pscustomobject]@{
        ExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        Output = $output.Trim()
    }
}

function Add-Check {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.ArrayList]$Checks,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Ready,
        [Parameter(Mandatory)][string]$Message,
        [string]$Detected = '',
        [string]$Required = '',
        [string]$Fix = ''
    )

    [void]$Checks.Add([ordered]@{
        name = $Name
        ready = $Ready
        detected = $Detected
        required = $Required
        message = $Message
        fix = $Fix
    })
}

$checks = [System.Collections.ArrayList]::new()

if ($env:OS -eq 'Windows_NT') {
    Add-Check -Checks $checks -Name 'windows' -Ready $true -Message '当前为 Windows 原生环境。' -Detected ([Environment]::OSVersion.VersionString) -Required 'Windows 10/11'
}
else {
    Add-Check -Checks $checks -Name 'windows' -Ready $false -Message '当前工具只支持 Windows 原生环境，不支持 WSL2 运行链路。' -Detected $env:OS -Required 'Windows 10/11'
}

$nodePath = Resolve-ToolCommand -Command $NodeCommand
if ($nodePath) {
    $nodeResult = Invoke-Tool -CommandPath $nodePath -Arguments @('--version')
    $nodeMatch = [regex]::Match($nodeResult.Output, 'v?(\d+)(?:\.\d+){1,3}')
    $nodeMajor = if ($nodeMatch.Success) { [int]$nodeMatch.Groups[1].Value } else { 0 }
    $nodeReady = $nodeResult.ExitCode -eq 0 -and $nodeMajor -ge 24
    $nodeMessage = if ($nodeReady) { 'Node.js 版本满足要求。' } else { 'Node.js 版本过低或无法识别，需要 24 或更高版本。' }
    Add-Check -Checks $checks -Name 'node' -Ready $nodeReady -Message $nodeMessage -Detected $nodeResult.Output -Required 'Node.js 24+' -Fix 'winget install OpenJS.NodeJS'
}
else {
    Add-Check -Checks $checks -Name 'node' -Ready $false -Message '未找到 Node.js。' -Required 'Node.js 24+' -Fix 'winget install OpenJS.NodeJS'
}

$pandocPath = Resolve-ToolCommand -Command $PandocCommand
if ($pandocPath) {
    $pandocResult = Invoke-Tool -CommandPath $pandocPath -Arguments @('--version') -NodePath $nodePath
    $pandocFirstLine = ($pandocResult.Output -split "`r?`n")[0]
    $pandocMatch = [regex]::Match($pandocFirstLine, '(\d+)(?:\.\d+)+')
    $pandocMajor = if ($pandocMatch.Success) { [int]$pandocMatch.Groups[1].Value } else { 0 }
    $pandocReady = $pandocResult.ExitCode -eq 0 -and $pandocMajor -ge 3
    $pandocMessage = if ($pandocReady) { 'Pandoc 版本满足要求。' } else { 'Pandoc 版本过低或无法识别，需要 3 或更高版本。' }
    Add-Check -Checks $checks -Name 'pandoc' -Ready $pandocReady -Message $pandocMessage -Detected $pandocFirstLine -Required 'Pandoc 3+' -Fix 'winget install JohnMacFarlane.Pandoc'
}
else {
    Add-Check -Checks $checks -Name 'pandoc' -Ready $false -Message '未找到 Pandoc。' -Required 'Pandoc 3+' -Fix 'winget install JohnMacFarlane.Pandoc'
}

$configuredProfile = ''
$configPath = ''
if ($DataDirectory) {
    $resolvedDataDirectory = [IO.Path]::GetFullPath($DataDirectory)
    $configPath = Join-Path $resolvedDataDirectory 'config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            $configuredProfile = [string]$config.profile
            $hasFolder = -not [string]::IsNullOrWhiteSpace([string]$config.folder)
            $hasWorkspace = -not [string]::IsNullOrWhiteSpace([string]$config.workspace)
            $configReady = $hasFolder -xor $hasWorkspace
            $configMessage = if ($configReady) { '默认钉钉目标配置有效。' } else { '配置必须且只能包含 folder 或 workspace。' }
            Add-Check -Checks $checks -Name 'config' -Ready $configReady -Message $configMessage -Detected $configPath -Required '一个默认 folder 或 workspace' -Fix 'n2dd config --folder <nodeId>'
        }
        catch {
            Add-Check -Checks $checks -Name 'config' -Ready $false -Message '配置文件无法解析。' -Detected $configPath -Required '有效 JSON 配置' -Fix 'n2dd config --clear'
        }
    }
    else {
        Add-Check -Checks $checks -Name 'config' -Ready $true -Message '尚未保存默认目标；迁移时仍可显式传入 --folder 或 --workspace。' -Required '可选' -Fix 'n2dd config --folder <nodeId>'
    }
}

$dwsPath = Resolve-ToolCommand -Command $DwsCommand
if ($dwsPath) {
    $dwsVersionResult = Invoke-Tool -CommandPath $dwsPath -Arguments @('--version') -NodePath $nodePath
    $dwsVersionMatch = [regex]::Match($dwsVersionResult.Output, 'v(\d+\.\d+\.\d+)')
    $dwsVersion = if ($dwsVersionMatch.Success) { $dwsVersionMatch.Groups[1].Value } else { '' }
    $dwsReady = $dwsVersionResult.ExitCode -eq 0 -and $dwsVersion -eq '1.0.59'
    $dwsMessage = if ($dwsReady) { 'DingTalk Workspace CLI 版本满足要求。' } else { 'dws 版本不匹配或无法识别，当前只验证了 1.0.59。' }
    $dwsDetected = if ($dwsVersion) { "$dwsVersion ($dwsPath)" } else { $dwsPath }
    Add-Check -Checks $checks -Name 'dws' -Ready $dwsReady -Message $dwsMessage -Detected $dwsDetected -Required 'dingtalk-workspace-cli 1.0.59' -Fix 'npm install -g dingtalk-workspace-cli@1.0.59'

    $authArguments = @('auth', 'status', '--format', 'json')
    if (-not [string]::IsNullOrWhiteSpace($configuredProfile)) {
        $authArguments += @('--profile', $configuredProfile)
    }
    $authResult = Invoke-Tool -CommandPath $dwsPath -Arguments $authArguments -NodePath $nodePath
    $authenticated = $false
    if ($authResult.ExitCode -eq 0 -and $authResult.Output) {
        try {
            $auth = $authResult.Output | ConvertFrom-Json
            $authenticated = $auth.authenticated -eq $true -and $auth.token_valid -ne $false
        }
        catch {
            $authenticated = $false
        }
    }
    $authenticated = $authenticated -and $dwsReady
    $authMessage = if ($authenticated) { '钉钉登录状态有效。' } else { '钉钉尚未登录、Token 已失效、dws 版本不匹配或状态无法读取。' }
    Add-Check -Checks $checks -Name 'dwsAuth' -Ready $authenticated -Message $authMessage -Required '有效 dws 登录状态' -Fix 'dws auth login'
}
else {
    Add-Check -Checks $checks -Name 'dws' -Ready $false -Message '未找到 DingTalk Workspace CLI。' -Required 'dingtalk-workspace-cli 1.0.59' -Fix 'npm install -g dingtalk-workspace-cli@1.0.59'
    Add-Check -Checks $checks -Name 'dwsAuth' -Ready $false -Message '安装 dws 后才能检查登录状态。' -Required '有效 dws 登录状态' -Fix 'dws auth login'
}

$requiredChecks = @($checks | Where-Object { $_.name -ne 'config' })
$ready = @($requiredChecks | Where-Object { -not $_.ready }).Count -eq 0
$fixes = @(
    $checks |
        Where-Object { -not $_.ready -and -not [string]::IsNullOrWhiteSpace($_.fix) } |
        ForEach-Object { $_.fix } |
        Select-Object -Unique
)

$result = [ordered]@{
    success = $ready
    ready = $ready
    checkedAt = [DateTime]::UtcNow.ToString('o')
    checks = @($checks)
    fixes = $fixes
}

$result | ConvertTo-Json -Depth 6
if (-not $NoExitCode -and -not $ready) {
    exit 1
}
