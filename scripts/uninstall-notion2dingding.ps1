[CmdletBinding()]
param([switch]$RunFromTemp, [switch]$Preview, [string]$PreviewImagePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$bundleRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configPath = Join-Path $bundleRoot 'uninstall-config.json'
if (-not $Preview -and -not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw '缺少卸载配置，请重新下载项目安装器并使用 -Action Uninstall。' }

# 把卸载代码复制到专属临时目录，避免删除正在使用的安装目录时被占用。
if (-not $RunFromTemp -and -not $Preview) {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('notion2dingding-uninstall-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    Copy-Item -LiteralPath (Join-Path $bundleRoot 'scripts') -Destination $tempRoot -Recurse
    Copy-Item -LiteralPath $configPath -Destination $tempRoot
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"' + (Join-Path $tempRoot 'scripts\uninstall-notion2dingding.ps1') + '"'),'-RunFromTemp')
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form
$form.Text = '卸载 Notion2DingDing'
$form.ClientSize = New-Object Drawing.Size(560,310)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI',10)
$form.BackColor = [Drawing.Color]::White
$label = New-Object Windows.Forms.Label
$label.Location = New-Object Drawing.Point(22,20)
$label.Size = New-Object Drawing.Size(516,100)
$label.Text = "卸载 Windows 本地助手？`r`n`r`n将删除本地核心、Native Host、项目配置及本项目安装的专属依赖。用户导出包、钉钉文档和其他工具安装的共享依赖会保留。"
$form.Controls.Add($label)
$logout = New-Object Windows.Forms.CheckBox
$logout.Location = New-Object Drawing.Point(22,128)
$logout.Size = New-Object Drawing.Size(516,30)
$logout.Text = '同时清除本机全部钉钉 DWS 登录状态'
$logout.Checked = $false
$form.Controls.Add($logout)
$hint = New-Object Windows.Forms.Label
$hint.Location = New-Object Drawing.Point(42,164)
$hint.Size = New-Object Drawing.Size(492,54)
$hint.ForeColor = [Drawing.Color]::FromArgb(95,95,95)
$hint.Text = '此选项会影响本机其他使用 DWS 的工具；之后需重新登录。默认保留登录状态。Edge 插件需单独移除。'
$form.Controls.Add($hint)
$cancel = New-Object Windows.Forms.Button
$cancel.Text = '取消'
$cancel.Location = New-Object Drawing.Point(318,246)
$cancel.Size = New-Object Drawing.Size(100,40)
$cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($cancel)
$remove = New-Object Windows.Forms.Button
$remove.Text = '确认卸载'
$remove.Location = New-Object Drawing.Point(430,246)
$remove.Size = New-Object Drawing.Size(106,40)
$remove.DialogResult = [Windows.Forms.DialogResult]::OK
$remove.Enabled = -not $Preview
$form.Controls.Add($remove)
$form.CancelButton = $cancel
try {
    if ($Preview -and $PreviewImagePath) {
        # 对本项目自己的 WinForms 确认窗做离屏渲染；不读取用户桌面。
        $bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
        try {
            $form.Show()
            [Windows.Forms.Application]::DoEvents()
            $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
            $bitmap.Save([IO.Path]::GetFullPath($PreviewImagePath), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $bitmap.Dispose() }
        exit 0
    }
    if ($form.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { exit 0 }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'install-release.ps1'),'-Action','Uninstall','-Quiet')
    foreach ($property in $config.PSObject.Properties) {
        if ($property.Value -is [bool]) { if ($property.Value) { $arguments += '-' + $property.Name } }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $arguments += @('-' + $property.Name, [string]$property.Value) }
    }
    if ($logout.Checked) { $arguments += '-RemoveDingtalkLogin' }
    $output = & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw $output.Trim() }
    [void][Windows.Forms.MessageBox]::Show('本地助手和项目专属依赖已卸载。你的源文件和钉钉文档保持不变。','卸载完成','OK','Information')
} catch {
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'卸载未完成','OK','Error')
    exit 1
} finally {
    $form.Dispose()
    if ($RunFromTemp) {
        $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $bundleRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($bundleRoot) -notlike 'notion2dingding-uninstall-*') { throw '卸载临时目录越界，拒绝清理。' }
        Remove-Item -LiteralPath $bundleRoot -Recurse -Force
        if (Test-Path -LiteralPath $bundleRoot) { throw '卸载临时目录清理失败。' }
    }
}
