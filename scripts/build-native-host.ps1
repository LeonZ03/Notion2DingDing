param(
    [switch]$TestOnly
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$nativeHostRoot = Join-Path $repositoryRoot 'apps\native-host'
$outputDirectory = Join-Path $repositoryRoot 'dist\native-host'
$outputPath = Join-Path $outputDirectory 'notion2dingding-host.exe'

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw 'Go 1.22+ is required to build the native host.'
}

Push-Location $nativeHostRoot
try {
    go test ./...
    if ($LASTEXITCODE -ne 0) {
        throw "Go tests failed with exit code $LASTEXITCODE."
    }

    if (-not $TestOnly) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
        go build -trimpath -o $outputPath ./cmd/notion2dingding-host
        if ($LASTEXITCODE -ne 0) {
            throw "Go build failed with exit code $LASTEXITCODE."
        }
        Write-Host "Native host built at $outputPath"
    }
}
finally {
    Pop-Location
}
