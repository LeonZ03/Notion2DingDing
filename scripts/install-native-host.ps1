param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-p]{32}$')]
    [string]$ExtensionId,

    [string]$HostExePath
)

$ErrorActionPreference = 'Stop'
$hostName = 'com.leonz03.notion2dingding'
$repositoryRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($HostExePath)) {
    $HostExePath = Join-Path $repositoryRoot 'dist\native-host\notion2dingding-host.exe'
}

$resolvedHostPath = (Resolve-Path -LiteralPath $HostExePath).Path
$installDirectory = Join-Path $env:LOCALAPPDATA 'Notion2DingDing'
$installedHostPath = Join-Path $installDirectory 'notion2dingding-host.exe'
$manifestPath = Join-Path $installDirectory "$hostName.json"
$registryPath = "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\$hostName"

New-Item -ItemType Directory -Force -Path $installDirectory | Out-Null
Copy-Item -LiteralPath $resolvedHostPath -Destination $installedHostPath -Force

$manifest = [ordered]@{
    name = $hostName
    description = 'Notion2DingDing Windows native messaging host'
    path = $installedHostPath
    type = 'stdio'
    allowed_origins = @("chrome-extension://$ExtensionId/")
} | ConvertTo-Json -Depth 4

[System.IO.File]::WriteAllText(
    $manifestPath,
    $manifest,
    [System.Text.UTF8Encoding]::new($false)
)

New-Item -Path $registryPath -Force | Out-Null
Set-Item -Path $registryPath -Value $manifestPath

Write-Host "Installed native host: $installedHostPath"
Write-Host "Registered manifest: $manifestPath"
