[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'SelfTest', Mandatory)]
    [switch]$SelfTest,

    [Parameter(ParameterSetName = 'Headless', Mandatory)]
    [switch]$Headless,

    [Parameter(ParameterSetName = 'Headless', Mandatory)]
    [Parameter(ParameterSetName = 'InferTitle', Mandatory)]
    [string]$InputPath,

    [Parameter(ParameterSetName = 'Headless')]
    [string]$DocumentName = '',

    [Parameter(ParameterSetName = 'Headless', Mandatory)]
    [ValidateSet('folder', 'workspace')]
    [string]$TargetType,

    [Parameter(ParameterSetName = 'Headless', Mandatory)]
    [string]$TargetId,

    [Parameter(ParameterSetName = 'Headless')]
    [string]$TargetDisplayName = '',

    [Parameter(ParameterSetName = 'Headless')]
    [Parameter(ParameterSetName = 'FolderBrowserProbe')]
    [string]$Profile = '',

    [Parameter(ParameterSetName = 'Headless')]
    [switch]$ForceMigration,

    [Parameter(ParameterSetName = 'Headless')]
    [ValidateSet('inline', 'tree')]
    [string]$MigrationMode = 'inline',

    [Parameter(ParameterSetName = 'InferTitle', Mandatory)]
    [switch]$InferTitle,

    [Parameter(ParameterSetName = 'FolderBrowserProbe', Mandatory)]
    [switch]$FolderBrowserProbe,

    [Parameter(ParameterSetName = 'FolderBrowserProbe')]
    [string]$FolderSearchQuery = '',

    [ValidateSet('', 'login', 'target')]
    [string]$OpenAction = '',

    [string]$DwsCommand = 'dws'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ($env:OS -ne 'Windows_NT') {
    throw '一键使用界面只支持 Windows 10/11 原生环境。'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.Windows.Forms.Application]::EnableVisualStyles()

$ownershipId = 'com.leonz03.notion2dingding.cli'
$programDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $programDirectory '.n2dd-install.json'
$cliScript = Join-Path $PSScriptRoot 'notion2dingding.ps1'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "安装状态不存在：$manifestPath。请重新安装 Notion2DingDing。"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.ownershipId -ne $ownershipId) {
    throw '安装目录所有权标记不匹配，拒绝启动界面。'
}
$dataDirectory = [IO.Path]::GetFullPath([string]$manifest.dataDirectory)
$configPath = Join-Path $dataDirectory 'config.json'

function ConvertTo-ProcessArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes += 1
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Start-CapturedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [switch]$Visible
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Value $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = -not $Visible
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "无法启动：$FilePath"
    }
    return $process
}

function Invoke-InstalledCommand {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)

    $process = Start-CapturedProcess -FilePath $powershellPath -Arguments (@(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $cliScript
    ) + $Arguments)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.Result.Trim()
    $stderr = $stderrTask.Result.Trim()
    $exitCode = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function ConvertFrom-CommandJson {
    param([AllowEmptyString()][string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $null
    }
    try {
        return $Output | ConvertFrom-Json
    }
    catch {
        $firstBrace = $Output.IndexOf('{')
        $lastBrace = $Output.LastIndexOf('}')
        if ($firstBrace -ge 0 -and $lastBrace -gt $firstBrace) {
            try {
                return $Output.Substring($firstBrace, $lastBrace - $firstBrace + 1) | ConvertFrom-Json
            }
            catch {
                return $null
            }
        }
        return $null
    }
}

function Get-CommandFailureMessage {
    param(
        [Parameter(Mandatory)]$CommandResult,
        [string]$Fallback = '操作失败。'
    )

    $parsed = ConvertFrom-CommandJson -Output $CommandResult.Stdout
    if ($parsed -and $parsed.error -and $parsed.error.message) {
        return [string]$parsed.error.message
    }
    if (-not [string]::IsNullOrWhiteSpace($CommandResult.Stderr)) {
        $lines = @($CommandResult.Stderr -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -gt 0) {
            return [string]$lines[-1]
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($CommandResult.Stdout)) {
        return $CommandResult.Stdout
    }
    return $Fallback
}

function Convert-HtmlTitleText {
    param([AllowEmptyString()][string]$Html)
    $text = [Text.RegularExpressions.Regex]::Replace($Html, '(?is)<[^>]+>', '')
    $text = [Net.WebUtility]::HtmlDecode($text)
    return ([Text.RegularExpressions.Regex]::Replace($text, '\s+', ' ')).Trim()
}

function Get-HtmlLinkTargets {
    param([Parameter(Mandatory)][string]$Content)
    $matches = [Text.RegularExpressions.Regex]::Matches(
        $Content,
        '(?is)<a\b[^>]*?\bhref\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')'
    )
    return @($matches | ForEach-Object {
        $value = if ($_.Groups['double'].Success) { $_.Groups['double'].Value } else { $_.Groups['single'].Value }
        [Net.WebUtility]::HtmlDecode($value)
    })
}

function Get-CleanNotionPageTitle {
    param([AllowEmptyString()][string]$EntryName, [AllowEmptyString()][string]$Html)
    $pageTitle = [Text.RegularExpressions.Regex]::Match(
        $Html,
        '(?is)<h1\b(?=[^>]*\bclass\s*=\s*["''][^"'']*\bpage-title\b[^"'']*["''])[^>]*>(?<title>.*?)</h1>'
    )
    if ($pageTitle.Success) {
        $title = Convert-HtmlTitleText -Html $pageTitle.Groups['title'].Value
        $title = ($title -replace '\s+[0-9a-fA-F]{32}$', '').Trim()
        if (-not [string]::IsNullOrWhiteSpace($title)) { return $title }
    }
    $headTitle = [Text.RegularExpressions.Regex]::Match($Html, '(?is)<title\b[^>]*>(?<title>.*?)</title>')
    if ($headTitle.Success) {
        $title = Convert-HtmlTitleText -Html $headTitle.Groups['title'].Value
        $title = ($title -replace '\s+[0-9a-fA-F]{32}$', '').Trim()
        if (-not [string]::IsNullOrWhiteSpace($title)) { return $title }
    }
    $candidate = [IO.Path]::GetFileNameWithoutExtension($EntryName)
    try { $candidate = [Uri]::UnescapeDataString($candidate) } catch { }
    $candidate = $candidate -replace '\s+[0-9a-fA-F]{32}$', ''
    $candidate = $candidate -replace '[_\s-]*ExportBlock-[0-9a-fA-F-]{36}$', ''
    if ($candidate -match '^(?i:[0-9a-f]{32}|[0-9a-f-]{36})$') { return '' }
    return $candidate.Trim()
}

function Resolve-ArchiveHtmlTarget {
    param(
        [Parameter(Mandatory)][string]$EntryPath,
        [Parameter(Mandatory)][string]$RawTarget
    )

    $target = [Net.WebUtility]::HtmlDecode($RawTarget).Trim()
    if ($target.StartsWith('#') -or $target -match '^(?i:https?|mailto|tel|data|file|javascript):' -or $target.StartsWith('//')) { return '' }
    $pathPart = ($target -split '[?#]', 2)[0]
    if ([string]::IsNullOrWhiteSpace($pathPart)) { return '' }
    try { $pathPart = [Uri]::UnescapeDataString($pathPart) } catch { return '' }
    if ([IO.Path]::IsPathRooted($pathPart)) { return '' }

    $virtualRoot = 'C:\n2dd-archive-root'
    $entryWindowsPath = $EntryPath.Replace('/', '\')
    $entryDirectory = [IO.Path]::GetDirectoryName((Join-Path $virtualRoot $entryWindowsPath))
    $resolved = [IO.Path]::GetFullPath((Join-Path $entryDirectory $pathPart.Replace('/', '\')))
    $rootPrefix = $virtualRoot.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $resolved.Substring($rootPrefix.Length).Replace('\', '/')
}

function Get-RootHtmlFromDirectory {
    param([Parameter(Mandatory)][string]$Root)

    $entries = @(Get-ChildItem -LiteralPath $Root -File -Recurse | Where-Object { $_.Extension -ieq '.html' -or $_.Extension -ieq '.htm' } | Sort-Object FullName)
    if ($entries.Count -eq 0) {
        if (@(Get-ChildItem -LiteralPath $Root -Filter '*.md' -File -Recurse).Count -gt 0) {
            throw '检测到 Markdown & CSV 导出；当前只支持 HTML。请重新导出并选择 HTML。'
        }
        throw '导出内容中没有找到 HTML 页面。'
    }
    $entrySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) { [void]$entrySet.Add($entry.FullName) }
    foreach ($entry in $entries) {
        $content = [IO.File]::ReadAllText($entry.FullName)
        foreach ($rawTarget in @(Get-HtmlLinkTargets -Content $content)) {
            $target = [Net.WebUtility]::HtmlDecode($rawTarget).Trim()
            if ($target.StartsWith('#') -or $target -match '^(?i:https?|mailto|tel|data|file|javascript):' -or $target.StartsWith('//')) { continue }
            $pathPart = ($target -split '[?#]', 2)[0]
            try { $pathPart = [Uri]::UnescapeDataString($pathPart) } catch { continue }
            if ([IO.Path]::IsPathRooted($pathPart)) { continue }
            $resolved = [IO.Path]::GetFullPath((Join-Path $entry.DirectoryName $pathPart.Replace('/', '\')))
            if ($entrySet.Contains($resolved)) { [void]$referenced.Add($resolved) }
        }
    }
    $roots = @($entries | Where-Object { -not $referenced.Contains($_.FullName) })
    if ($roots.Count -ne 1) {
        throw "无法唯一识别 Notion 根页面（候选 $($roots.Count) 个），请只导出一个页面及其子页面。"
    }
    return [pscustomobject]@{
        Name = $roots[0].Name
        Html = [IO.File]::ReadAllText($roots[0].FullName)
    }
}

function Get-RootHtmlFromArchive {
    param(
        [Parameter(Mandatory)][IO.Compression.ZipArchive]$Archive,
        [int]$Depth = 0
    )

    $entries = @($Archive.Entries | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.Name) -and
        $_.Name.EndsWith('.html', [StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.EndsWith('.htm', [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object FullName)
    if ($entries.Count -eq 0) {
        $nestedZips = @($Archive.Entries | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Name) -and
            $_.Name.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)
        })
        if ($nestedZips.Count -eq 0) {
            $markdown = @($Archive.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) -and $_.Name.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase) })
            if ($markdown.Count -gt 0) { throw '检测到 Markdown & CSV 导出；当前只支持 HTML。请重新导出并选择 HTML。' }
            throw 'ZIP 中没有找到 HTML 页面。'
        }
        if ($nestedZips.Count -ne 1) { throw "ZIP 中包含 $($nestedZips.Count) 个内层导出包，无法唯一识别目标页面。" }
        if ($Depth -ge 2) { throw 'ZIP 嵌套超过 3 层，已停止读取。' }
        $nestedStream = $nestedZips[0].Open()
        $nestedArchive = [IO.Compression.ZipArchive]::new($nestedStream, [IO.Compression.ZipArchiveMode]::Read, $false)
        try { return Get-RootHtmlFromArchive -Archive $nestedArchive -Depth ($Depth + 1) }
        finally {
            $nestedArchive.Dispose()
            $nestedStream.Dispose()
        }
    }
        $contentByPath = @{}
        $entryByPath = @{}
        foreach ($entry in $entries) {
            $key = $entry.FullName.Replace('\', '/').TrimStart('/')
            $reader = [IO.StreamReader]::new($entry.Open(), [Text.UTF8Encoding]::new($false), $true)
            try { $contentByPath[$key] = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $entryByPath[$key] = $entry
        }
        $referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($entryByPath.Keys)) {
            foreach ($rawTarget in @(Get-HtmlLinkTargets -Content ([string]$contentByPath[$key]))) {
                $targetKey = Resolve-ArchiveHtmlTarget -EntryPath $key -RawTarget $rawTarget
                if ($targetKey -and $entryByPath.ContainsKey($targetKey)) { [void]$referenced.Add($targetKey) }
            }
        }
        $roots = @($entryByPath.Keys | Where-Object { -not $referenced.Contains($_) } | Sort-Object)
        if ($roots.Count -ne 1) {
            throw "无法唯一识别 Notion 根页面（候选 $($roots.Count) 个），请只导出一个页面及其子页面。"
        }
        $rootKey = [string]$roots[0]
        return [pscustomobject]@{
            Name = [string]$entryByPath[$rootKey].Name
            Html = [string]$contentByPath[$rootKey]
        }
}

function Get-RootHtmlFromZip {
    param([Parameter(Mandatory)][string]$Path)

    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        return Get-RootHtmlFromArchive -Archive $archive
    }
    finally {
        $archive.Dispose()
    }
}

function Get-SuggestedDocumentName {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $rootPage = Get-RootHtmlFromDirectory -Root $resolved
    }
    elseif (Test-Path -LiteralPath $resolved -PathType Leaf) {
        if (-not [IO.Path]::GetExtension($resolved).Equals('.zip', [StringComparison]::OrdinalIgnoreCase)) {
            throw '输入文件必须是 Notion 导出的 ZIP。'
        }
        $rootPage = Get-RootHtmlFromZip -Path $resolved
    }
    else {
        throw "输入路径不存在：$resolved"
    }
    $title = Get-CleanNotionPageTitle -EntryName $rootPage.Name -Html $rootPage.Html
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = [IO.Path]::GetFileNameWithoutExtension($resolved)
        $title = $title -replace '[_\s-]*ExportBlock-[0-9a-fA-F-]{36}$', ''
    }
    if ([string]::IsNullOrWhiteSpace($title)) { return 'Notion 迁移文档' }
    return $title.Trim()
}

function Invoke-DwsJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$Dws = 'dws',
        [string]$DwsProfile = ''
    )

    $finalArguments = @($Arguments) + @('--format', 'json')
    if (-not [string]::IsNullOrWhiteSpace($DwsProfile)) {
        $finalArguments += @('--profile', $DwsProfile)
    }
    if ([IO.Path]::GetExtension($Dws).Length -eq 0) {
        $resolvedDws = Get-Command $Dws -ErrorAction Stop
        $Dws = [string]$resolvedDws.Source
    }
    $extension = [IO.Path]::GetExtension($Dws).ToLowerInvariant()
    if ($extension -in @('.js', '.mjs', '.cjs')) {
        $node = Get-Command node -ErrorAction Stop
        $process = Start-CapturedProcess -FilePath $node.Source -Arguments (@([IO.Path]::GetFullPath($Dws)) + $finalArguments)
    }
    elseif ($extension -eq '.ps1') {
        $process = Start-CapturedProcess -FilePath $powershellPath -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', [IO.Path]::GetFullPath($Dws)) + $finalArguments)
    }
    elseif ($extension -in @('.cmd', '.bat')) {
        $process = Start-CapturedProcess -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments (@('/d', '/c', [IO.Path]::GetFullPath($Dws)) + $finalArguments)
    }
    else {
        $process = Start-CapturedProcess -FilePath $Dws -Arguments $finalArguments
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.Result.Trim()
    $stderr = $stderrTask.Result.Trim()
    $exitCode = $process.ExitCode
    $process.Dispose()
    $parsed = ConvertFrom-CommandJson -Output $stdout
    if ($exitCode -ne 0 -or -not $parsed) {
        $message = if ($parsed -and $parsed.error -and $parsed.error.message) { [string]$parsed.error.message } elseif ($stderr) { $stderr } else { $stdout }
        throw "读取钉钉文件夹失败：$message"
    }
    return $parsed
}

function Get-DingTalkFolderRoots {
    param([string]$Dws = 'dws', [string]$DwsProfile = '')

    $roots = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($spaceType in @('mySpace', 'orgSpace')) {
        $cursor = ''
        for ($page = 0; $page -lt 20; $page += 1) {
            $arguments = @('wiki', 'space', 'list', '--type', $spaceType, '--limit', '50')
            if ($cursor) { $arguments += @('--cursor', $cursor) }
            try {
                $response = Invoke-DwsJson -Arguments $arguments -Dws $Dws -DwsProfile $DwsProfile
            }
            catch {
                $errors.Add($_.Exception.Message)
                break
            }
            if (-not $response.success -or -not $response.result -or -not $response.result.PSObject.Properties['items']) {
                $errors.Add("钉钉空间列表返回不完整：$spaceType")
                break
            }
            foreach ($item in @($response.result.items)) {
                if ([string]::IsNullOrWhiteSpace([string]$item.spaceName) -or [string]::IsNullOrWhiteSpace([string]$item.rootFolderId)) {
                    throw "钉钉空间条目缺少名称或根文件夹 ID：$spaceType"
                }
                $roots.Add([pscustomobject]@{
                    Name = [string]$item.spaceName
                    Id = [string]$item.rootFolderId
                    SpaceId = [string]$item.spaceId
                    SpaceType = [string]$item.spaceType
                })
            }
            $nextTokenProperty = $response.result.PSObject.Properties['nextToken']
            $cursor = if ($nextTokenProperty) { [string]$nextTokenProperty.Value } else { '' }
            if (-not $cursor) { break }
            if ($page -eq 19) { throw '钉钉空间超过 1000 个，已停止加载，避免无界请求。' }
        }
    }
    if ($roots.Count -eq 0) {
        $details = if ($errors.Count -gt 0) { $errors -join '；' } else { '当前账号没有可用文档空间。' }
        throw "没有可选择的钉钉文件夹：$details"
    }
    return @($roots)
}

function Get-DingTalkChildFolders {
    param(
        [Parameter(Mandatory)][string]$FolderId,
        [string]$Dws = 'dws',
        [string]$DwsProfile = ''
    )

    $folders = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $cursor = ''
    for ($page = 0; $page -lt 20; $page += 1) {
        $arguments = @('drive', '+list', '--folder', $FolderId, '--limit', '50', '--order-by', 'name', '--order', 'asc')
        if ($cursor) { $arguments += @('--cursor', $cursor) }
        $response = Invoke-DwsJson -Arguments $arguments -Dws $Dws -DwsProfile $DwsProfile
        if (-not $response.ok -or $response.outcome -ne 'success' -or -not $response.data -or -not $response.data.PSObject.Properties['files']) {
            throw '钉钉文件夹列表返回不完整，无法安全展示目录。'
        }
        foreach ($item in @($response.data.files)) {
            if (-not $item.PSObject.Properties['type'] -or -not $item.PSObject.Properties['name'] -or -not $item.PSObject.Properties['nodeId']) {
                throw '钉钉目录中存在字段不完整的条目，已停止加载。'
            }
            if ([string]$item.type -ieq 'FOLDER' -and $seen.Add([string]$item.nodeId)) {
                $folders.Add([pscustomobject]@{ Name = [string]$item.name; Id = [string]$item.nodeId })
            }
        }
        $cursorProperty = $response.data.PSObject.Properties['nextCursor']
        $cursor = if ($cursorProperty) { [string]$cursorProperty.Value } else { '' }
        if (-not $cursor) { break }
        if ($page -eq 19) { throw "文件夹 $FolderId 的子项超过 1000 个，已停止加载，避免静默截断。" }
    }
    return @($folders)
}

function Search-DingTalkFolders {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$Dws = 'dws',
        [string]$DwsProfile = ''
    )

    $normalizedQuery = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedQuery)) {
        throw '请输入要搜索的钉钉文件夹名称。'
    }

    $folders = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $cursor = ''
    for ($page = 0; $page -lt 20; $page += 1) {
        $arguments = @('drive', '+search', '--query', $normalizedQuery, '--limit', '30')
        if ($cursor) { $arguments += @('--cursor', $cursor) }
        $response = Invoke-DwsJson -Arguments $arguments -Dws $Dws -DwsProfile $DwsProfile
        if (-not $response.ok -or $response.outcome -ne 'success' -or -not $response.data -or -not $response.data.PSObject.Properties['files']) {
            throw '钉钉文件夹搜索返回不完整，无法安全展示结果。'
        }
        foreach ($item in @($response.data.files)) {
            if (-not $item.PSObject.Properties['type'] -or -not $item.PSObject.Properties['name'] -or -not $item.PSObject.Properties['nodeId']) {
                throw '钉钉搜索结果中存在字段不完整的条目，已停止加载。'
            }
            if ([string]$item.type -ieq 'FOLDER' -and $seen.Add([string]$item.nodeId)) {
                $folders.Add([pscustomobject]@{ Name = [string]$item.name; Id = [string]$item.nodeId })
            }
        }
        $cursorProperty = $response.data.PSObject.Properties['nextCursor']
        $cursor = if ($cursorProperty) { [string]$cursorProperty.Value } else { '' }
        if (-not $cursor) { break }
        if ($page -eq 19) { throw '文件夹搜索结果超过 600 项，已停止加载，避免静默截断。' }
    }
    return @($folders)
}

function Show-DingTalkFolderPicker {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.IWin32Window]$Owner,
        [string]$Dws = 'dws',
        [string]$DwsProfile = ''
    )

    $roots = @(Get-DingTalkFolderRoots -Dws $Dws -DwsProfile $DwsProfile)
    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = '选择钉钉文件夹'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = [Drawing.Size]::new(600, 510)
    $dialog.MinimumSize = [Drawing.Size]::new(616, 549)
    $dialog.Font = [Drawing.Font]::new('Microsoft YaHei UI', 9)

    $hint = [System.Windows.Forms.Label]::new()
    $hint.Text = '可按名称搜索，或展开空间节点读取下一层目录。'
    $hint.Location = [Drawing.Point]::new(18, 16)
    $hint.AutoSize = $true
    $dialog.Controls.Add($hint)

    $tree = [System.Windows.Forms.TreeView]::new()
    $tree.Name = 'DingTalkFolderTree'
    $searchBox = [System.Windows.Forms.TextBox]::new()
    $searchBox.Name = 'DingTalkFolderSearchQuery'
    $searchBox.Location = [Drawing.Point]::new(18, 46)
    $searchBox.Size = [Drawing.Size]::new(458, 28)
    $dialog.Controls.Add($searchBox)

    $searchButton = [System.Windows.Forms.Button]::new()
    $searchButton.Name = 'SearchDingTalkFolder'
    $searchButton.Text = '搜索'
    $searchButton.Location = [Drawing.Point]::new(486, 44)
    $searchButton.Size = [Drawing.Size]::new(96, 30)
    $dialog.Controls.Add($searchButton)

    $tree.Location = [Drawing.Point]::new(18, 82)
    $tree.Size = [Drawing.Size]::new(564, 349)
    $tree.HideSelection = $false
    $tree.PathSeparator = ' / '
    $dialog.Controls.Add($tree)

    $selectionLabel = [System.Windows.Forms.Label]::new()
    $selectionLabel.Text = '尚未选择文件夹'
    $selectionLabel.Location = [Drawing.Point]::new(18, 442)
    $selectionLabel.Size = [Drawing.Size]::new(390, 28)
    $dialog.Controls.Add($selectionLabel)

    $okButton = [System.Windows.Forms.Button]::new()
    $okButton.Text = '选择此文件夹'
    $okButton.Location = [Drawing.Point]::new(418, 440)
    $okButton.Size = [Drawing.Size]::new(104, 32)
    $okButton.Enabled = $false
    $dialog.Controls.Add($okButton)

    $cancelButton = [System.Windows.Forms.Button]::new()
    $cancelButton.Text = '取消'
    $cancelButton.Location = [Drawing.Point]::new(530, 440)
    $cancelButton.Size = [Drawing.Size]::new(52, 32)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)
    $dialog.CancelButton = $cancelButton

    foreach ($root in $roots) {
        $node = [System.Windows.Forms.TreeNode]::new($root.Name)
        $node.Tag = [pscustomobject]@{ Id = $root.Id; Loaded = $false }
        [void]$node.Nodes.Add([System.Windows.Forms.TreeNode]::new('正在读取…'))
        [void]$tree.Nodes.Add($node)
    }

    $searchResultsNode = $null
    $runSearch = {
        $query = $searchBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($query)) {
            $selectionLabel.Text = '请输入文件夹名称后再搜索。'
            return
        }
        $dialog.UseWaitCursor = $true
        $searchButton.Enabled = $false
        $selectionLabel.Text = '正在全局搜索钉钉文件夹……'
        $dialog.Refresh()
        try {
            $matches = @(Search-DingTalkFolders -Query $query -Dws $Dws -DwsProfile $DwsProfile)
            if ($searchResultsNode) { $tree.Nodes.Remove($searchResultsNode) }
            $searchResultsNode = [System.Windows.Forms.TreeNode]::new("搜索结果（$($matches.Count)）")
            $searchResultsNode.Tag = $null
            foreach ($match in $matches) {
                $matchNode = [System.Windows.Forms.TreeNode]::new($match.Name)
                $matchNode.Tag = [pscustomobject]@{ Id = $match.Id; Loaded = $false; DisplayPath = $match.Name }
                [void]$matchNode.Nodes.Add([System.Windows.Forms.TreeNode]::new('正在读取…'))
                [void]$searchResultsNode.Nodes.Add($matchNode)
            }
            [void]$tree.Nodes.Insert(0, $searchResultsNode)
            $searchResultsNode.Expand()
            $selectionLabel.Text = if ($matches.Count -eq 0) { '没有找到同名文件夹，请缩短关键词重试。' } else { "找到 $($matches.Count) 个文件夹，请选择目标。" }
        }
        catch {
            $selectionLabel.Text = '搜索失败，请检查权限或登录状态。'
            [void][System.Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, '无法搜索钉钉文件夹', 'OK', 'Error')
        }
        finally {
            $searchButton.Enabled = $true
            $dialog.UseWaitCursor = $false
        }
    }.GetNewClosure()

    $searchButton.Add_Click($runSearch)
    $searchBox.Add_KeyDown(({
        param($sender, $eventArgs)
        if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $eventArgs.SuppressKeyPress = $true
            & $runSearch
        }
    }).GetNewClosure())

    $tree.Add_BeforeExpand(({
        param($sender, $eventArgs)
        $tag = $eventArgs.Node.Tag
        if (-not $tag) { return }
        if ($tag.Loaded) { return }
        $dialog.UseWaitCursor = $true
        $selectionLabel.Text = '正在读取子文件夹……'
        $dialog.Refresh()
        try {
            $children = @(Get-DingTalkChildFolders -FolderId $tag.Id -Dws $Dws -DwsProfile $DwsProfile)
            $eventArgs.Node.Nodes.Clear()
            foreach ($child in $children) {
                $childNode = [System.Windows.Forms.TreeNode]::new($child.Name)
                $childNode.Tag = [pscustomobject]@{ Id = $child.Id; Loaded = $false }
                [void]$childNode.Nodes.Add([System.Windows.Forms.TreeNode]::new('正在读取…'))
                [void]$eventArgs.Node.Nodes.Add($childNode)
            }
            $tag.Loaded = $true
            $selectionLabel.Text = if ($children.Count -eq 0) { '此文件夹没有子文件夹，可以直接选择当前文件夹。' } else { '请选择目标文件夹。' }
        }
        catch {
            $eventArgs.Cancel = $true
            $selectionLabel.Text = '读取失败，请检查权限或登录状态。'
            [void][System.Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, '无法读取钉钉文件夹', 'OK', 'Error')
        }
        finally {
            $dialog.UseWaitCursor = $false
        }
    }).GetNewClosure())
    $tree.Add_AfterSelect(({
        param($sender, $eventArgs)
        $selectionLabel.Text = $eventArgs.Node.FullPath
        $okButton.Enabled = $null -ne $eventArgs.Node.Tag
    }).GetNewClosure())
    $okButton.Add_Click(({
        if ($tree.SelectedNode -and $tree.SelectedNode.Tag) {
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    }).GetNewClosure())

    try {
        if ($dialog.ShowDialog($Owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return [pscustomobject]@{
            Id = [string]$tree.SelectedNode.Tag.Id
            Path = if ($tree.SelectedNode.Tag.PSObject.Properties['DisplayPath']) { [string]$tree.SelectedNode.Tag.DisplayPath } else { [string]$tree.SelectedNode.FullPath }
        }
    }
    finally {
        $dialog.Dispose()
    }
}

function Invoke-GuiMigration {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [AllowEmptyString()][string]$Title = '',
        [Parameter(Mandatory)][ValidateSet('folder', 'workspace')][string]$DestinationType,
        [Parameter(Mandatory)][string]$DestinationId,
        [string]$DestinationDisplayName = '',
        [string]$DwsProfile = '',
        [string]$Dws = 'dws',
        [ValidateSet('inline', 'tree')][string]$SubpageMode = 'inline',
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return [ordered]@{ success = $false; stage = 'input'; message = "Notion 导出包或目录不存在：$SourcePath"; fixes = @() }
    }
    if ([string]::IsNullOrWhiteSpace($Title)) {
        try { $Title = Get-SuggestedDocumentName -Path $SourcePath }
        catch { return [ordered]@{ success = $false; stage = 'input'; message = "无法自动识别 Notion 标题：$($_.Exception.Message)"; fixes = @() } }
    }
    if ([string]::IsNullOrWhiteSpace($DestinationId)) {
        return [ordered]@{ success = $false; stage = 'config'; message = '请填写钉钉目标 ID。'; fixes = @() }
    }

    $configArguments = @('config', "--$DestinationType", $DestinationId)
    if ($DestinationType -eq 'folder' -and -not [string]::IsNullOrWhiteSpace($DestinationDisplayName)) {
        $configArguments += @('--folder-name', $DestinationDisplayName)
    }
    if (-not [string]::IsNullOrWhiteSpace($DwsProfile)) {
        $configArguments += @('--profile', $DwsProfile)
    }
    $configResult = Invoke-InstalledCommand -Arguments $configArguments
    if ($configResult.ExitCode -ne 0) {
        return [ordered]@{
            success = $false
            stage = 'config'
            message = Get-CommandFailureMessage -CommandResult $configResult -Fallback '无法保存钉钉目标配置。'
            fixes = @()
        }
    }

    $doctorArguments = @('doctor', '-NoExitCode')
    if ($Dws -ne 'dws') {
        $doctorArguments += @('-DwsCommand', $Dws)
    }
    $doctorResult = Invoke-InstalledCommand -Arguments $doctorArguments
    $doctor = ConvertFrom-CommandJson -Output $doctorResult.Stdout
    if ($doctorResult.ExitCode -ne 0 -or -not $doctor -or -not $doctor.ready) {
        $fixes = if ($doctor -and $doctor.fixes) { @($doctor.fixes) } else { @('请点击“检查环境”查看修复建议。') }
        return [ordered]@{
            success = $false
            stage = 'doctor'
            message = '运行环境尚未准备好，请按界面中的修复建议处理后重试。'
            fixes = $fixes
        }
    }

    $migrationArguments = @('migrate', '--input', [IO.Path]::GetFullPath($SourcePath), '--name', $Title)
    if ($SubpageMode -eq 'tree') {
        $migrationArguments += @('--subpages', 'tree')
    }
    if ($Dws -ne 'dws') {
        $migrationArguments += @('--dws-path', $Dws)
    }
    if ($Force) {
        $migrationArguments += '--force'
    }
    $migrationResult = Invoke-InstalledCommand -Arguments $migrationArguments
    $migration = ConvertFrom-CommandJson -Output $migrationResult.Stdout
    if ($migrationResult.ExitCode -ne 0 -or -not $migration -or -not $migration.success) {
        return [ordered]@{
            success = $false
            stage = 'migration'
            message = Get-CommandFailureMessage -CommandResult $migrationResult -Fallback '迁移失败，请检查导出包和钉钉权限。'
            fixes = @()
        }
    }

    $documentUrl = [string]$migration.remote.documentUrl
    if ([string]::IsNullOrWhiteSpace($documentUrl)) {
        return [ordered]@{ success = $false; stage = 'verify'; message = '迁移结果缺少钉钉文档链接，不能报告成功。'; fixes = @() }
    }
    $titleAdjusted = [bool]($migration.checks -and $migration.checks.titleAdjusted)
    $titleCollisionIndex = if ($titleAdjusted) { [int]$migration.checks.titleCollisionIndex } else { 0 }
    $displayTitle = if ($titleAdjusted) { "$Title($titleCollisionIndex)" } else { $Title }
    $resumedReadback = [bool]($migration.checks -and $migration.checks.resumedReadback)
    $nativeTodoCount = if ($migration.checks -and $migration.checks.todosMatch) { [int]$migration.checks.nativeTodoCount } else { 0 }
    $nativeCodeBlockCount = if ($migration.checks -and $migration.checks.codeBlocksMatch) { [int]$migration.checks.nativeCodeBlockCount } else { 0 }
    $nativeLayoutCount = if ($migration.checks -and $migration.checks.layoutsMatch) { [int]$migration.checks.nativeLayoutCount } else { 0 }
    $nativeSubpageTocItemCount = if ($migration.checks -and $migration.checks.subpageTocMatches) { [int]$migration.checks.nativeSubpageTocItemCount } else { 0 }
    $recursivePageCount = if ($migration.checks -and $migration.checks.PSObject.Properties['recursivePageCount']) { [int]$migration.checks.recursivePageCount } else { 0 }
    $recursiveFolderCount = if ($migration.checks -and $migration.checks.PSObject.Properties['recursiveFolderCount']) { [int]$migration.checks.recursiveFolderCount } else { 0 }
    $recursiveLinkCount = if ($migration.checks -and $migration.checks.PSObject.Properties['recursiveLinkCount']) { [int]$migration.checks.recursiveLinkCount } else { 0 }
    $message = if ($migration.reused) {
        '已找到相同迁移结果，没有创建重复文档。'
    }
    elseif ($titleAdjusted) {
        "转换完成；目标文件夹已有同名文档，钉钉将标题调整为《$displayTitle》。临时文件已经永久清理。"
    }
    elseif ($resumedReadback) {
        '已有文档的回读验证已恢复完成，没有重复导入；临时文件已经永久清理。'
    }
    else {
        '转换完成，临时文件已经永久清理。'
    }
    if ($nativeTodoCount -gt 0) {
        $message += " 已恢复 $nativeTodoCount 个钉钉原生可点击待办。"
    }
    if ($nativeCodeBlockCount -gt 0) {
        $message += " 已恢复 $nativeCodeBlockCount 个钉钉原生代码块。"
    }
    if ($nativeLayoutCount -gt 0) {
        $message += " 已恢复 $nativeLayoutCount 个无表格边框的钉钉原生分栏。"
    }
    if ($nativeSubpageTocItemCount -gt 0) {
        $message += " 已生成包含 $nativeSubpageTocItemCount 个子页面的原生目录。"
    }
    if ($SubpageMode -eq 'tree') {
        $message += " 已递归创建 $recursiveFolderCount 个文件夹、$recursivePageCount 个独立文档，并回填 $recursiveLinkCount 个钉钉跳转链接。"
    }
    return [ordered]@{
        success = $true
        stage = 'complete'
        message = $message
        documentUrl = $documentUrl
        title = $displayTitle
        requestedTitle = $Title
        titleAdjusted = $titleAdjusted
        resumedReadback = $resumedReadback
        nativeTodoCount = $nativeTodoCount
        nativeTodoVerified = [bool]($migration.checks -and $migration.checks.todosMatch)
        nativeCodeBlockCount = $nativeCodeBlockCount
        nativeCodeBlocksVerified = [bool]($migration.checks -and $migration.checks.codeBlocksMatch)
        nativeLayoutCount = $nativeLayoutCount
        nativeLayoutsVerified = [bool]($migration.checks -and $migration.checks.layoutsMatch)
        nativeSubpageTocItemCount = $nativeSubpageTocItemCount
        nativeSubpageTocVerified = [bool]($migration.checks -and $migration.checks.subpageTocMatches)
        subpageMode = $SubpageMode
        recursivePageCount = $recursivePageCount
        recursiveFolderCount = $recursiveFolderCount
        recursiveLinkCount = $recursiveLinkCount
        reused = [bool]$migration.reused
        cleanupVerified = if ($migration.reused) { $true } else { [bool]$migration.local.docx.permanentlyDeleted }
        fixes = @()
    }
}

function New-MainForm {
    $form = [System.Windows.Forms.Form]::new()
    $form.Name = 'Notion2DingDingMainForm'
    $form.Text = 'Notion2DingDing'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = [Drawing.Size]::new(760, 630)
    $form.MinimumSize = [Drawing.Size]::new(776, 669)
    $form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 9)
    $form.AllowDrop = $true

    $titleLabel = [System.Windows.Forms.Label]::new()
    $titleLabel.Text = 'Notion → 钉钉文档'
    $titleLabel.Font = [Drawing.Font]::new('Microsoft YaHei UI', 18, [Drawing.FontStyle]::Bold)
    $titleLabel.Location = [Drawing.Point]::new(24, 18)
    $titleLabel.AutoSize = $true
    $form.Controls.Add($titleLabel)

    $subtitle = [System.Windows.Forms.Label]::new()
    $subtitle.Text = '选择 Notion 的 HTML 导出包，多栏布局和图片会迁移到钉钉文档。'
    $subtitle.ForeColor = [Drawing.Color]::DimGray
    $subtitle.Location = [Drawing.Point]::new(28, 58)
    $subtitle.AutoSize = $true
    $form.Controls.Add($subtitle)

    $inputLabel = [System.Windows.Forms.Label]::new()
    $inputLabel.Text = '1. Notion HTML 导出 ZIP 或目录（也可以直接拖进窗口）'
    $inputLabel.Location = [Drawing.Point]::new(28, 96)
    $inputLabel.AutoSize = $true
    $form.Controls.Add($inputLabel)

    $inputBox = [System.Windows.Forms.TextBox]::new()
    $inputBox.Name = 'InputPath'
    $inputBox.Location = [Drawing.Point]::new(28, 120)
    $inputBox.Size = [Drawing.Size]::new(552, 28)
    $form.Controls.Add($inputBox)

    $zipButton = [System.Windows.Forms.Button]::new()
    $zipButton.Name = 'SelectZip'
    $zipButton.Text = '选择 ZIP'
    $zipButton.Location = [Drawing.Point]::new(590, 118)
    $zipButton.Size = [Drawing.Size]::new(70, 30)
    $form.Controls.Add($zipButton)

    $folderButton = [System.Windows.Forms.Button]::new()
    $folderButton.Name = 'SelectDirectory'
    $folderButton.Text = '选择目录'
    $folderButton.Location = [Drawing.Point]::new(666, 118)
    $folderButton.Size = [Drawing.Size]::new(70, 30)
    $form.Controls.Add($folderButton)

    $nameLabel = [System.Windows.Forms.Label]::new()
    $nameLabel.Text = '2. 文档标题（从 Notion 根页面自动读取，可修改）'
    $nameLabel.Location = [Drawing.Point]::new(28, 164)
    $nameLabel.AutoSize = $true
    $form.Controls.Add($nameLabel)

    $nameBox = [System.Windows.Forms.TextBox]::new()
    $nameBox.Name = 'DocumentName'
    $nameBox.Location = [Drawing.Point]::new(28, 188)
    $nameBox.Size = [Drawing.Size]::new(708, 28)
    $form.Controls.Add($nameBox)

    $targetLabel = [System.Windows.Forms.Label]::new()
    $targetLabel.Text = '3. 钉钉文件夹（直接选择，首次设置后会自动保存）'
    $targetLabel.Location = [Drawing.Point]::new(28, 232)
    $targetLabel.AutoSize = $true
    $form.Controls.Add($targetLabel)

    $targetBox = [System.Windows.Forms.TextBox]::new()
    $targetBox.Name = 'TargetFolder'
    $targetBox.Location = [Drawing.Point]::new(28, 256)
    $targetBox.Size = [Drawing.Size]::new(540, 28)
    $targetBox.ReadOnly = $true
    $targetBox.Text = '尚未选择钉钉文件夹'
    $form.Controls.Add($targetBox)

    $targetButton = [System.Windows.Forms.Button]::new()
    $targetButton.Name = 'SelectDingTalkFolder'
    $targetButton.Text = '选择钉钉文件夹'
    $targetButton.Location = [Drawing.Point]::new(578, 254)
    $targetButton.Size = [Drawing.Size]::new(158, 32)
    $form.Controls.Add($targetButton)

    $profileLabel = [System.Windows.Forms.Label]::new()
    $profileLabel.Text = 'DWS profile（通常留空）'
    $profileLabel.Location = [Drawing.Point]::new(28, 299)
    $profileLabel.AutoSize = $true
    $form.Controls.Add($profileLabel)

    $profileBox = [System.Windows.Forms.TextBox]::new()
    $profileBox.Name = 'Profile'
    $profileBox.Location = [Drawing.Point]::new(196, 294)
    $profileBox.Size = [Drawing.Size]::new(252, 28)
    $form.Controls.Add($profileBox)

    $modeLabel = [System.Windows.Forms.Label]::new()
    $modeLabel.Text = '子页面'
    $modeLabel.Location = [Drawing.Point]::new(466, 299)
    $modeLabel.AutoSize = $true
    $form.Controls.Add($modeLabel)

    $modeBox = [System.Windows.Forms.ComboBox]::new()
    $modeBox.Name = 'SubpageMode'
    $modeBox.Location = [Drawing.Point]::new(524, 294)
    $modeBox.Size = [Drawing.Size]::new(212, 28)
    $modeBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$modeBox.Items.Add('在同页面内展开（默认）')
    [void]$modeBox.Items.Add('递归文档树（每页独立文档）')
    $modeBox.SelectedIndex = 0
    $form.Controls.Add($modeBox)

    $doctorButton = [System.Windows.Forms.Button]::new()
    $doctorButton.Name = 'Doctor'
    $doctorButton.Text = '检查环境'
    $doctorButton.Location = [Drawing.Point]::new(28, 336)
    $doctorButton.Size = [Drawing.Size]::new(100, 34)
    $form.Controls.Add($doctorButton)

    $loginButton = [System.Windows.Forms.Button]::new()
    $loginButton.Name = 'Login'
    $loginButton.Text = '登录钉钉'
    $loginButton.Location = [Drawing.Point]::new(138, 336)
    $loginButton.Size = [Drawing.Size]::new(100, 34)
    $form.Controls.Add($loginButton)

    $startButton = [System.Windows.Forms.Button]::new()
    $startButton.Name = 'StartMigration'
    $startButton.Text = '开始转换'
    $startButton.BackColor = [Drawing.Color]::FromArgb(22, 119, 255)
    $startButton.ForeColor = [Drawing.Color]::White
    $startButton.FlatStyle = 'Flat'
    $startButton.Location = [Drawing.Point]::new(586, 332)
    $startButton.Size = [Drawing.Size]::new(150, 42)
    $form.Controls.Add($startButton)

    $progress = [System.Windows.Forms.ProgressBar]::new()
    $progress.Name = 'Progress'
    $progress.Location = [Drawing.Point]::new(28, 388)
    $progress.Size = [Drawing.Size]::new(708, 8)
    $progress.Style = 'Blocks'
    $form.Controls.Add($progress)

    $statusBox = [System.Windows.Forms.RichTextBox]::new()
    $statusBox.Name = 'Status'
    $statusBox.Location = [Drawing.Point]::new(28, 412)
    $statusBox.Size = [Drawing.Size]::new(708, 134)
    $statusBox.ReadOnly = $true
    $statusBox.BackColor = [Drawing.Color]::White
    $statusBox.BorderStyle = 'FixedSingle'
    $statusBox.Text = "准备就绪。`r`n选择 Notion 导出包后会自动读取标题；首次使用请直接选择钉钉文件夹。"
    $form.Controls.Add($statusBox)

    $resultLink = [System.Windows.Forms.LinkLabel]::new()
    $resultLink.Name = 'DocumentLink'
    $resultLink.Text = '打开生成的钉钉文档'
    $resultLink.Location = [Drawing.Point]::new(28, 562)
    $resultLink.AutoSize = $true
    $resultLink.Visible = $false
    $form.Controls.Add($resultLink)

    $privacy = [System.Windows.Forms.Label]::new()
    $privacy.Text = '源导出包会保留；工具生成的 DOCX、解压目录和图片副本会永久清理。'
    $privacy.ForeColor = [Drawing.Color]::DimGray
    $privacy.Location = [Drawing.Point]::new(28, 600)
    $privacy.AutoSize = $true
    $form.Controls.Add($privacy)

    $state = [pscustomobject]@{
        ActiveProcess = $null
        LastDocumentUrl = ''
        SelectedTargetId = ''
        EventSelfTest = $false
        OpenControlName = ''
    }
    $form.Tag = $state
    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 300

    $setSelectedInput = ({
        param([string]$SelectedPath)
        if ([string]::IsNullOrWhiteSpace($SelectedPath)) { return }
        $inputBox.Text = [IO.Path]::GetFullPath($SelectedPath)
        try {
            $nameBox.Text = Get-SuggestedDocumentName -Path $inputBox.Text
            $statusBox.Text = "已从 Notion 根页面读取标题：$($nameBox.Text)"
        }
        catch {
            $statusBox.Text = "已选择输入，但无法自动读取标题：$($_.Exception.Message)"
        }
    }).GetNewClosure()

    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $savedConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$savedConfig.folder)) {
                $state.SelectedTargetId = [string]$savedConfig.folder
                $folderNameProperty = $savedConfig.PSObject.Properties['folderName']
                $targetBox.Text = if ($folderNameProperty -and -not [string]::IsNullOrWhiteSpace([string]$folderNameProperty.Value)) {
                    [string]$folderNameProperty.Value
                }
                else {
                    '已保存的钉钉文件夹（可点击右侧重新选择）'
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$savedConfig.workspace)) {
                $statusBox.Text = '旧配置使用 workspace，请重新选择一个钉钉文件夹。'
            }
            $profileBox.Text = [string]$savedConfig.profile
        }
        catch {
            $statusBox.Text = '已发现损坏的目标配置，请重新填写后开始转换。'
        }
    }

    $zipButton.Add_Click(({
        if ($state.EventSelfTest) {
            $statusBox.Text = 'ZIP_EVENT_OK'
            return
        }
        $dialog = [System.Windows.Forms.OpenFileDialog]::new()
        $dialog.Title = '选择 Notion HTML 导出的 ZIP'
        $dialog.Filter = 'ZIP 压缩包 (*.zip)|*.zip'
        $dialog.Multiselect = $false
        try {
            if ($dialog.ShowDialog($form) -eq 'OK') {
                & $setSelectedInput -SelectedPath $dialog.FileName
            }
        }
        finally {
            $dialog.Dispose()
        }
    }).GetNewClosure())

    $folderButton.Add_Click(({
        if ($state.EventSelfTest) {
            $statusBox.Text = 'DIRECTORY_EVENT_OK'
            return
        }
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = '选择已解压的 Notion HTML 导出目录'
        try {
            if ($dialog.ShowDialog($form) -eq 'OK') {
                & $setSelectedInput -SelectedPath $dialog.SelectedPath
            }
        }
        finally {
            $dialog.Dispose()
        }
    }).GetNewClosure())

    $form.Add_DragEnter(({
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        }
    }).GetNewClosure())
    $form.Add_DragDrop(({
        param($sender, $eventArgs)
        $paths = @($eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
        if ($paths.Count -gt 0) {
            & $setSelectedInput -SelectedPath ([string]$paths[0])
        }
    }).GetNewClosure())

    $targetButton.Add_Click(({
        if ($state.EventSelfTest) {
            $statusBox.Text = 'DINGTALK_FOLDER_EVENT_OK'
            return
        }
        if ($state.ActiveProcess -and -not $state.ActiveProcess.HasExited) { return }
        $statusBox.Text = '正在读取钉钉文档空间和文件夹……'
        $form.Refresh()
        try {
            $selection = Show-DingTalkFolderPicker -Owner $form -Dws $DwsCommand -DwsProfile $profileBox.Text
            if ($selection) {
                $state.SelectedTargetId = [string]$selection.Id
                $targetBox.Text = [string]$selection.Path
                $configArguments = @('config', '--folder', [string]$selection.Id, '--folder-name', [string]$selection.Path)
                if (-not [string]::IsNullOrWhiteSpace($profileBox.Text)) {
                    $configArguments += @('--profile', $profileBox.Text)
                }
                $configResult = Invoke-InstalledCommand -Arguments $configArguments
                $config = ConvertFrom-CommandJson -Output $configResult.Stdout
                if ($configResult.ExitCode -ne 0 -or -not $config -or -not $config.success) {
                    throw (Get-CommandFailureMessage -CommandResult $configResult -Fallback '无法保存钉钉目标配置。')
                }
                $statusBox.Text = "已选择并保存钉钉文件夹：$($selection.Path)`r`n现在可关闭窗口并回到 Edge 点击「重新检查环境」。"
            }
            else {
                $statusBox.Text = '没有更改钉钉目标文件夹。'
            }
        }
        catch {
            $statusBox.Text = "无法读取钉钉文件夹：$($_.Exception.Message)`r`n请先点击「登录钉钉」，授权文档和钉盘相关业务域后重试。"
        }
    }).GetNewClosure())

    $doctorButton.Add_Click(({
        if ($state.EventSelfTest) {
            $statusBox.Text = 'DOCTOR_EVENT_OK'
            return
        }
        $statusBox.Text = '正在检查 Node.js、Pandoc、dws 和钉钉登录状态……'
        $form.Refresh()
        try {
            $doctorResult = Invoke-InstalledCommand -Arguments @('doctor', '-NoExitCode')
            $doctor = ConvertFrom-CommandJson -Output $doctorResult.Stdout
            if ($doctor -and $doctor.ready) {
                $statusBox.Text = '环境检查通过，可以开始转换。'
            }
            elseif ($doctor) {
                $messages = @($doctor.checks | Where-Object { -not $_.ready } | ForEach-Object { "• $($_.message)" })
                $fixes = @($doctor.fixes | ForEach-Object { "  $($_)" })
                $statusBox.Text = (@('环境尚未准备好：') + $messages + @('', '修复命令：') + $fixes) -join "`r`n"
            }
            else {
                $statusBox.Text = Get-CommandFailureMessage -CommandResult $doctorResult -Fallback '环境检查失败。'
            }
        }
        catch {
            $statusBox.Text = "环境检查失败：$($_.Exception.Message)"
        }
    }).GetNewClosure())

    $loginButton.Add_Click(({
        if ($state.EventSelfTest) {
            $statusBox.Text = 'LOGIN_EVENT_OK'
            return
        }
        try {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/c', 'dws auth login')
            $statusBox.Text = '已启动钉钉登录。请在新窗口或浏览器完成授权，然后回到这里点击“检查环境”。'
        }
        catch {
            $statusBox.Text = "无法启动钉钉登录：$($_.Exception.Message)"
        }
    }).GetNewClosure())

    $startButton.Add_Click(({
        if ($state.EventSelfTest) {
            $statusBox.Text = 'START_EVENT_OK'
            return
        }
        if ($state.ActiveProcess -and -not $state.ActiveProcess.HasExited) { return }
        if (-not (Test-Path -LiteralPath $inputBox.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show($form, '请先选择有效的 Notion 导出 ZIP 或目录。', '输入无效', 'OK', 'Warning')
            return
        }
        if ([string]::IsNullOrWhiteSpace($nameBox.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show($form, '请填写迁移后的文档标题。', '标题为空', 'OK', 'Warning')
            return
        }
        if ([string]::IsNullOrWhiteSpace($state.SelectedTargetId)) {
            [void][System.Windows.Forms.MessageBox]::Show($form, '请点击“选择钉钉文件夹”并选择文档保存位置。', '尚未选择文件夹', 'OK', 'Warning')
            return
        }

        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-STA',
            '-File', $PSCommandPath,
            '-Headless',
            '-InputPath', $inputBox.Text,
            '-DocumentName', $nameBox.Text,
            '-TargetType', 'folder',
            '-TargetId', $state.SelectedTargetId,
            '-TargetDisplayName', $targetBox.Text,
            '-MigrationMode', $(if ($modeBox.SelectedIndex -eq 1) { 'tree' } else { 'inline' })
        )
        if (-not [string]::IsNullOrWhiteSpace($profileBox.Text)) {
            $arguments += @('-Profile', $profileBox.Text)
        }
        $state.LastDocumentUrl = ''
        $resultLink.Visible = $false
        $statusBox.Text = "正在检查环境、保存目标并转换……`r`n文档较大时可能需要几分钟，请不要关闭窗口。"
        $progress.Style = 'Marquee'
        $startButton.Enabled = $false
        $doctorButton.Enabled = $false
        $loginButton.Enabled = $false
        $targetButton.Enabled = $false
        try {
            $state.ActiveProcess = Start-CapturedProcess -FilePath $powershellPath -Arguments $arguments
            $timer.Start()
        }
        catch {
            $progress.Style = 'Blocks'
            $startButton.Enabled = $true
            $doctorButton.Enabled = $true
            $loginButton.Enabled = $true
            $targetButton.Enabled = $true
            $statusBox.Text = "无法启动转换：$($_.Exception.Message)"
        }
    }).GetNewClosure())

    $timer.Add_Tick(({
        if (-not $state.ActiveProcess -or -not $state.ActiveProcess.HasExited) { return }
        $timer.Stop()
        $process = $state.ActiveProcess
        $process.WaitForExit()
        $stdout = $process.StandardOutput.ReadToEnd().Trim()
        $stderr = $process.StandardError.ReadToEnd().Trim()
        $exitCode = $process.ExitCode
        $process.Dispose()
        $state.ActiveProcess = $null
        $progress.Style = 'Blocks'
        $startButton.Enabled = $true
        $doctorButton.Enabled = $true
        $loginButton.Enabled = $true
        $targetButton.Enabled = $true

        $result = ConvertFrom-CommandJson -Output $stdout
        if ($exitCode -eq 0 -and $result -and $result.success) {
            $state.LastDocumentUrl = [string]$result.documentUrl
            $statusBox.Text = "转换成功。`r`n$($result.message)`r`n点击下方链接打开钉钉文档。"
            $resultLink.Links.Clear()
            [void]$resultLink.Links.Add(0, $resultLink.Text.Length, $state.LastDocumentUrl)
            $resultLink.Visible = $true
        }
        elseif ($result) {
            $fixText = if ($result.fixes -and @($result.fixes).Count -gt 0) { "`r`n`r`n建议：`r`n" + (@($result.fixes) -join "`r`n") } else { '' }
            $statusBox.Text = "转换未完成：$($result.message)$fixText"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $statusBox.Text = "转换未完成：$stderr"
        }
        else {
            $statusBox.Text = '转换未完成，未能读取工具返回结果。请点击“检查环境”后重试。'
        }
    }).GetNewClosure())

    $resultLink.Add_LinkClicked(({
        if ($state.EventSelfTest) {
            $statusBox.Text = 'RESULT_LINK_EVENT_OK'
            return
        }
        if (-not [string]::IsNullOrWhiteSpace($state.LastDocumentUrl)) {
            Start-Process -FilePath $state.LastDocumentUrl
        }
    }).GetNewClosure())

    $form.Add_FormClosing(({
        param($sender, $eventArgs)
        if ($state.ActiveProcess -and -not $state.ActiveProcess.HasExited) {
            $eventArgs.Cancel = $true
            [void][System.Windows.Forms.MessageBox]::Show($form, '正在转换并清理临时文件，请等待完成后再关闭。', '转换进行中', 'OK', 'Information')
        }
    }).GetNewClosure())

    return $form
}

function Add-OpenActionHandler {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Form]$Form,
        [ValidateSet('login', 'target')][string]$Action
    )

    $Form.Tag.OpenControlName = if ($Action -eq 'login') { 'Login' } else { 'SelectDingTalkFolder' }
    $Form.Add_Shown({
        param($sender, $eventArgs)
        $button = $sender.Controls.Find([string]$sender.Tag.OpenControlName, $true)[0]
        if ($button) {
            if ($sender.Tag.EventSelfTest) {
                $onClick = [System.Windows.Forms.Button].GetMethod(
                    'OnClick',
                    [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
                )
                [void]$onClick.Invoke($button, @([EventArgs]::Empty))
            }
            else {
                $sender.TopMost = $true
                [void]$sender.Activate()
                $sender.BringToFront()
                try {
                    $button.PerformClick()
                }
                finally {
                    $sender.TopMost = $false
                    $sender.Close()
                }
            }
        }
    })
}

if ($InferTitle) {
    try {
        [ordered]@{
            success = $true
            title = Get-SuggestedDocumentName -Path $InputPath
        } | ConvertTo-Json
        exit 0
    }
    catch {
        [ordered]@{
            success = $false
            error = $_.Exception.Message
        } | ConvertTo-Json
        exit 1
    }
}

if ($FolderBrowserProbe) {
    try {
        $roots = @(Get-DingTalkFolderRoots -Dws $DwsCommand -DwsProfile $Profile)
        $children = @(Get-DingTalkChildFolders -FolderId $roots[0].Id -Dws $DwsCommand -DwsProfile $Profile)
        $searchResults = if ([string]::IsNullOrWhiteSpace($FolderSearchQuery)) { @() } else { @(Search-DingTalkFolders -Query $FolderSearchQuery -Dws $DwsCommand -DwsProfile $Profile) }
        [ordered]@{
            success = $true
            roots = $roots
            firstRootChildren = $children
            searchResults = $searchResults
        } | ConvertTo-Json -Depth 5
        exit 0
    }
    catch {
        [ordered]@{ success = $false; error = $_.Exception.Message } | ConvertTo-Json
        exit 1
    }
}

if ($SelfTest) {
    $testForm = New-MainForm
    try {
        $testForm.Tag.EventSelfTest = $true
        $statusControl = $testForm.Controls.Find('Status', $true)[0]
        $subpageModeControl = $testForm.Controls.Find('SubpageMode', $true)[0]
        $eventChecks = [ordered]@{}
        $onClick = [System.Windows.Forms.Button].GetMethod(
            'OnClick',
            [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
        )
        foreach ($controlName in @('SelectZip', 'SelectDirectory', 'SelectDingTalkFolder', 'Doctor', 'Login', 'StartMigration')) {
            $button = $testForm.Controls.Find($controlName, $true)[0]
            [void]$onClick.Invoke($button, @([EventArgs]::Empty))
            $eventChecks[$controlName] = $statusControl.Text.EndsWith('_EVENT_OK', [StringComparison]::Ordinal)
        }
        Add-OpenActionHandler -Form $testForm -Action target
        $onShown = [System.Windows.Forms.Form].GetMethod(
            'OnShown',
            [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
        )
        [void]$onShown.Invoke($testForm, @([EventArgs]::Empty))
        $openActionReady = $statusControl.Text -eq 'DINGTALK_FOLDER_EVENT_OK'
        [ordered]@{
            success = $true
            windowsForms = $true
            formName = $testForm.Name
            supportsDragDrop = [bool]$testForm.AllowDrop
            controls = @($testForm.Controls | ForEach-Object { $_.Name } | Where-Object { $_ })
            eventHandlersReady = -not ($eventChecks.Values -contains $false)
            eventChecks = $eventChecks
            openActionReady = $openActionReady
            defaultSubpageMode = if ($subpageModeControl.SelectedIndex -eq 0) { 'inline' } else { 'tree' }
        } | ConvertTo-Json -Depth 4
    }
    finally {
        $testForm.Dispose()
    }
    exit 0
}

if ($Headless) {
    $result = Invoke-GuiMigration `
        -SourcePath $InputPath `
        -Title $DocumentName `
        -DestinationType $TargetType `
        -DestinationId $TargetId `
        -DestinationDisplayName $TargetDisplayName `
        -DwsProfile $Profile `
        -Dws $DwsCommand `
        -SubpageMode $MigrationMode `
        -Force:$ForceMigration
    $result | ConvertTo-Json -Depth 6
    if ($result.success) { exit 0 }
    exit 1
}

$mainForm = New-MainForm
try {
    if (-not [string]::IsNullOrWhiteSpace($OpenAction)) {
        Add-OpenActionHandler -Form $mainForm -Action $OpenAction
    }
    [void]$mainForm.ShowDialog()
}
finally {
    $mainForm.Dispose()
}
