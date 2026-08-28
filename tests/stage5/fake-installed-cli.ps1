param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Write-JsonLine {
    param($Value)
    [Console]::Out.Write(($Value | ConvertTo-Json -Depth 8 -Compress))
}

if ($Command -eq 'version') {
    Write-JsonLine ([ordered]@{ success = $true; version = '0.1.0-stage5-test' })
    exit 0
}

if ($Command -eq 'doctor') {
    Write-JsonLine ([ordered]@{
        success = $true
        ready = $true
        checks = @(
            [ordered]@{ name = 'config'; ready = $true }
            [ordered]@{ name = 'dwsAuth'; ready = $true }
        )
    })
    exit 0
}

if ($Command -eq 'inspect') {
    $inputPath = $null
    for ($index = 0; $index -lt $Remaining.Count; $index++) {
        if ($Remaining[$index] -eq '--input' -and $index + 1 -lt $Remaining.Count) {
            $inputPath = $Remaining[++$index]
        }
    }
    if (-not $inputPath -or -not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        Write-JsonLine ([ordered]@{ success = $false; error = 'input missing' })
        exit 3
    }
    Write-JsonLine ([ordered]@{
        success = $true
        inputFormat = 'html'
        mode = 'manifest'
        title = '导出包识别标题'
        exportedAt = '2026-08-28T02:00:00.0000000Z'
        pageCount = 3
    })
    exit 0
}

if ($Command -ne 'migrate') {
    Write-JsonLine ([ordered]@{ success = $false; error = @{ code = 'UNKNOWN_COMMAND'; message = 'unknown' } })
    exit 2
}

$inputPath = $null
$title = ''
$subpageMode = 'inline'
$createNew = $false
for ($index = 0; $index -lt $Remaining.Count; $index++) {
    if ($Remaining[$index] -eq '--input' -and $index + 1 -lt $Remaining.Count) {
        $inputPath = $Remaining[++$index]
        continue
    }
    if ($Remaining[$index] -eq '--name' -and $index + 1 -lt $Remaining.Count) {
        $title = $Remaining[++$index]
        continue
    }
    if ($Remaining[$index] -eq '--subpages' -and $index + 1 -lt $Remaining.Count) {
        $subpageMode = $Remaining[++$index]
        continue
    }
    if ($Remaining[$index] -eq '--force') {
        $createNew = $true
    }
}
if (-not $inputPath -or -not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
    Write-JsonLine ([ordered]@{ success = $false; error = @{ code = 'INPUT_MISSING'; message = 'input missing' } })
    exit 3
}

[Console]::Error.WriteLine('[1/5] preflight')
if ($title -eq 'cancel-me') {
    Start-Sleep -Seconds 30
}
if ($env:N2DD_FAKE_STAGE6_DELAY -eq '1') {
    Start-Sleep -Milliseconds 250
}
[Console]::Error.WriteLine('[2/5] convert')
if ($env:N2DD_FAKE_STAGE6_DELAY -eq '1') {
    Start-Sleep -Milliseconds 250
}
[Console]::Error.WriteLine('[3/5] import')
if ($env:N2DD_FAKE_STAGE6_DELAY -eq '1') {
    Start-Sleep -Milliseconds 250
}
[Console]::Error.WriteLine('[4/5] verify')
if ($env:N2DD_FAKE_STAGE6_DELAY -eq '1') {
    Start-Sleep -Milliseconds 250
}
[Console]::Error.WriteLine('[5/5] cleanup')

$algorithm = [Security.Cryptography.SHA256]::Create()
$stream = [IO.File]::OpenRead($inputPath)
try {
    $sha256 = ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
}
finally {
    $stream.Dispose()
    $algorithm.Dispose()
}
$imageCount = if ($title -eq 'multi-image') { 8 } elseif ($title -eq 'long-page') { 2 } else { 1 }
$todoCount = if ($title -eq 'ordinary') { 3 } else { 0 }
$codeBlockCount = if ($title -eq 'ordinary') { 2 } else { 0 }
if (-not [string]::IsNullOrWhiteSpace($env:N2DD_FAKE_LOG)) {
    $logValue = [ordered]@{
        sha256 = $sha256
        title = $title
        inputName = [IO.Path]::GetFileName($inputPath)
        subpageMode = $subpageMode
        createNew = $createNew
    } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText(
        $env:N2DD_FAKE_LOG,
        "$logValue`n",
        [Text.UTF8Encoding]::new($false)
    )
}

Write-JsonLine ([ordered]@{
    success = $true
    status = 'SUCCESS'
    stage = 'verified'
    taskId = $sha256.Substring(0, 24)
    reused = $false
    remote = [ordered]@{
        taskId = "remote-$($sha256.Substring(0, 8))"
        documentUrl = "https://alidocs.dingtalk.com/i/nodes/$($sha256.Substring(0, 24))"
    }
    checks = [ordered]@{
        expectedImageCount = $imageCount
        readbackImageCount = $imageCount
        nativeTodoCount = $todoCount
        nativeCodeBlockCount = $codeBlockCount
        nativeSubpageTocItemCount = if ($title -eq 'ordinary') { 2 } else { 0 }
        recursivePageCount = if ($subpageMode -eq 'tree') { 3 } else { 0 }
        recursiveFolderCount = if ($subpageMode -eq 'tree') { 3 } else { 0 }
        recursiveLinkCount = if ($subpageMode -eq 'tree') { 2 } else { 0 }
        todosMatch = $true
    }
    cleanup = [ordered]@{ verified = $true }
})
