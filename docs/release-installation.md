# 正式版安装、升级与卸载

## 推荐安装流程

1. 从 Microsoft Edge Add-ons 获取 Notion2DingDing 扩展。
2. 第一次打开扩展时，如果本地助手未安装，点击“下载并安装”。
3. 运行 `Notion2DingDing-Setup.exe`。安装器会在当前 Windows 用户范围内安装本地迁移核心和 Native Messaging Host，并在缺少时通过 winget/npm 安装固定版本的 Node.js、Pandoc 和钉钉官方 dws。
4. 完全关闭并重新打开 Edge。
5. 打开扩展，按提示完成一次钉钉登录和保存位置选择。
6. 本地核心变为绿色后，日常迁移只需使用 Edge 扩展。

Edge 官方明确说明 Native Messaging 本机程序不由 Edge 安装或管理，因此首次安装由“Edge 扩展 + Windows 本地助手”两步组成；完成后无需日常打开终端或本地界面。

## v0.1.0 未签名安装提示

首个公开版本的 `Notion2DingDing-Setup.exe` 暂未进行 Authenticode 代码签名。Windows 或 Edge SmartScreen 可能显示“Windows 已保护你的电脑”或阻止不常见下载。这不影响 Edge 商店扩展本身；Edge Add-ons 会对扩展包执行自己的签名与审核。

仅当安装包来自本项目官方 GitHub Release，并且 SHA-256 与同一发布页的 `checksums.sha256` 一致时继续：

1. 在 Windows 提示中选择“更多信息”。
2. 确认应用名称为 `Notion2DingDing-Setup.exe`。
3. 选择“仍要运行”。

不要运行来自聊天转发、网盘或其他第三方地址的同名安装包。后续版本计划接入受信任的 Windows 代码签名；升级到签名版本时仍可保留当前用户配置和最小任务状态。

## 安装位置

- 本地迁移核心：`%LOCALAPPDATA%\Programs\Notion2DingDing`
- Native Host：`%LOCALAPPDATA%\Programs\Notion2DingDingNativeHost`
- 配置和最小状态：`%LOCALAPPDATA%\Notion2DingDing`
- 命令入口：`%LOCALAPPDATA%\Microsoft\WindowsApps\n2dd.cmd`
- Native Host 注册：当前用户 `HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.leonz03.notion2dingding`

安装器不需要管理员权限，不写入系统级 Native Messaging 注册表。

## 升级

扩展会检查 Native Host 版本、本地核心版本和必需能力。发现不兼容时会显示“下载最新版”。再次运行最新版 `Notion2DingDing-Setup.exe` 会自动选择升级模式，保留当前用户的钉钉授权、保存位置和最小任务状态。

发布页同时提供 `checksums.sha256`。下载后可运行：

```powershell
Get-FileHash .\Notion2DingDing-Setup.exe -Algorithm SHA256
```

将结果与发布页校验和核对。

## 卸载

发布包的备用 ZIP 中提供 `scripts\Uninstall-Notion2DingDing.cmd`。它只删除带有本项目所有权标记的本地核心、Native Host、配置、最小状态、启动器和当前用户注册项；不会删除用户提供的 Notion ZIP 或已经创建的钉钉文档。

Edge 扩展需要在 `edge://extensions` 或 Edge Add-ons 页面单独卸载。

## 当前限制

- v0.1.0 安装器未进行 Authenticode 代码签名，因此首次安装可能出现 SmartScreen 提示；发布清单会如实标记 `codeSigned=false`。
- 安装包已写入 Microsoft Edge Add-ons 分配的正式 CRX ID，并同时允许开发 ID和商店 ID连接 Native Host。
- 项目源代码许可证仍需项目所有者确认。

## 备用安装包

如果需要检查安装内容，可下载 `Notion2DingDing-Setup-Files-v<版本>.zip`，解压后运行 `scripts\Install-Notion2DingDing.cmd`。该备用方式与 EXE 使用同一个 PowerShell 安装核心。
