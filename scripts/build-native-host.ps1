param(
    [switch]$TestOnly
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$nativeHostRoot = Join-Path $repositoryRoot 'apps\native-host'
$outputDirectory = Join-Path $repositoryRoot 'dist\native-host'
$outputPath = Join-Path $outputDirectory 'notion2dingding-host.exe'

$goCommand = Get-Command go -ErrorAction SilentlyContinue
if (-not $goCommand) {
    $userGo = Join-Path $env:LOCALAPPDATA 'Programs\Go\bin\go.exe'
    if (Test-Path -LiteralPath $userGo -PathType Leaf) {
        $goCommand = Get-Item -LiteralPath $userGo
    }
}
if (-not $goCommand) {
    throw 'Go 1.22+ is required to build the native host.'
}
$goPath = $goCommand.Source
if ([string]::IsNullOrWhiteSpace($goPath)) {
    $goPath = $goCommand.FullName
}
$goVersion = & $goPath version
if ($LASTEXITCODE -ne 0 -or $goVersion -notmatch 'go version go(?<major>\d+)\.(?<minor>\d+)') {
    throw '无法读取 Go 版本。'
}
if ([int]$Matches.major -lt 1 -or ([int]$Matches.major -eq 1 -and [int]$Matches.minor -lt 22)) {
    throw "需要 Go 1.22+，当前为：$goVersion"
}
if ([string]::IsNullOrWhiteSpace($env:GOCACHE)) {
    $env:GOCACHE = Join-Path $env:TEMP 'notion2dingding-go-build'
}

Push-Location $nativeHostRoot
try {
    & $goPath test ./...
    if ($LASTEXITCODE -ne 0) {
        throw "Go tests failed with exit code $LASTEXITCODE."
    }

    if (-not $TestOnly) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
        & $goPath build -trimpath -o $outputPath ./cmd/notion2dingding-host
        if ($LASTEXITCODE -ne 0) {
            throw "Go build failed with exit code $LASTEXITCODE."
        }
        Write-Host "Native host built at $outputPath"
    }
}
finally {
    Pop-Location
}
