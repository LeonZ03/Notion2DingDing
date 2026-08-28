# Windows 开发指南

## 0. 本地 CLI 安装与验收

阶段 4 的用户级 CLI 不依赖 Edge 或 Go。程序、数据和命令入口分离：

```text
%LOCALAPPDATA%\Programs\Notion2DingDing   程序文件与所有权标记
%LOCALAPPDATA%\Notion2DingDing            配置与最小幂等状态
%LOCALAPPDATA%\Microsoft\WindowsApps\n2dd.cmd
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Notion2DingDing\Notion2DingDing.lnk
```

```powershell
npm run install:local
npm run upgrade:local
npm run uninstall:local
```

安装后从 Windows 开始菜单启动 `Notion2DingDing`。一键界面只接受 Notion HTML 导出 ZIP/目录，从根 HTML 页面的 `page-title` 或 `<title>` 自动推断标题，通过 DWS 浏览“我的文件”和企业文档空间的目录树，并执行保留多栏布局的迁移。普通用户不需要查询或填写 `nodeId`；CLI 仍保留显式 ID，供自动化与故障排查：

```powershell
n2dd doctor
n2dd config --folder "<TARGET_FOLDER_NODE_ID>"
n2dd migrate --input "C:\path\to\notion-export.zip"
```

安装和升级只复制迁移所需的运行时脚本，不复制夹具、源码历史或 `node_modules`。开始菜单快捷方式通过 Windows Script Host 无控制台窗口地启动 WinForms，避免直接指向 PowerShell 的快捷方式被 Windows 开始菜单安全策略自动移除。升级先构建同级暂存目录，再替换带所有权标记的旧程序目录；配置与最小状态独立保留。卸载在删除前校验程序、数据、命令启动器和开始菜单目录的所有权标记，不修改 PATH 或系统级注册表。

隔离验收：

```powershell
npm run test:stage4
```

该测试在系统临时目录模拟全新用户根目录，完成安装、Windows Forms 界面自检、HTML-only 拒绝规则、随机 ZIP 名下的根 HTML 标题识别、三图同排和图片/表格同排的 DOCX 结构审计、DWS 文件夹树与全局搜索、Notion 待办到钉钉原生待办、界面迁移、升级、卸载和防误删检查，最后永久删除整个测试根目录。

## 1. 扩展

```powershell
npm install
npm run check:extension
```

打开 `edge://extensions`：

1. 启用“开发人员模式”。
2. 点击“加载解压缩的扩展”。
3. 选择 `dist/edge-extension`。
4. 核对固定扩展 ID 为 `hheldkapioofhdbblmgfokdnpgfgaafo`。

## 2. 本地助手

安装 Go 1.22 或更高版本后（本机阶段 5 验证版本为 `1.26.7`）：

```powershell
npm run check:native
npm run build:native
```

构建输出位于：

```text
dist/native-host/notion2dingding-host.exe
```

## 3. 注册 Native Messaging Host

```powershell
npm run install:native
npm run status:native
npm run doctor:native
```

脚本执行以下操作：

- 将助手复制到 `%LOCALAPPDATA%\Programs\Notion2DingDingNativeHost`
- 从扩展固定公钥计算 ID，生成只允许该扩展 ID 的 Host Manifest
- 写入当前用户的 Edge Native Messaging Host 注册表项

重新打开扩展弹窗，状态应显示本地助手版本、`windows/amd64`、阶段 4 本地核心状态、钉钉登录状态和已保存的目标显示路径。弹窗可通过 `local.open` 打开 Windows 工具中的 DWS 登录入口或钉钉文件夹选择器；目标 ID 与凭据不会返回扩展。升级与卸载均会先校验所有权标记：

```powershell
npm run upgrade:native
npm run uninstall:native
```

Native Host 只接受带 4 字节小端长度前缀的 JSON；stdout 不输出日志。`health.check` 返回真实本地工具状态，`local.open` 仅允许 `login`/`target` 两种白名单操作。Edge 对 ZIP 使用 512 KiB Base64 分片发送到扩展后台，后台完整核对后再交给 Native Host；扩展入口限制原始 ZIP 不超过 46 MiB，为浏览器到 Native Host 的 64 MiB 消息上限保留 JSON 与 Base64 膨胀余量。Native Host 暂存到工具自有任务目录，调用已安装 CLI 后永久删除副本。自动验收：

Edge 的单次 `sendNativeMessage` 会在响应后结束 Native Host 的 Windows Job Object；因此 `local.open` 启动的 WinForms 设置进程使用 `CREATE_BREAKAWAY_FROM_JOB` 脱离该 Job，并继续用 `CREATE_NO_WINDOW` 隐藏控制台。同步执行的迁移进程不使用脱离标志。

```powershell
npm run test:stage5
npm run check:all
```

## 4. 钉钉依赖

真实迁移前，需要安装并登录 DingTalk Workspace CLI：

```powershell
dws auth login
dws auth status --format json
```

本地开发不在仓库中保存 DWS Token、AppKey 或 AppSecret。

## 5. 发布候选包

阶段 7 使用固定白名单组装发布内容，不直接压缩仓库：

```powershell
npm run check:stage7
npm run build:release
```

输出位于 `dist/release/v<版本>`，包含 Edge Add-ons ZIP、`Notion2DingDing-Setup.exe`、备用可审计安装 ZIP、`checksums.sha256`、隐私说明和第三方组件清单。`release-manifest.json` 会明确记录是否已经提供 Edge Add-ons 正式扩展 ID以及安装器是否代码签名。

Microsoft Edge Add-ons 分配正式 ID 后，重新构建：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-release.ps1 `
  -PublishedExtensionId "<32位Edge扩展ID>"
```

正式 Edge Add-ons 身份已写入 `apps/edge-extension/store-identity.json` 后，可省略
`-PublishedExtensionId`；显式参数仍可用于隔离测试或其他商店身份构建。

最终 Native Host 清单会同时允许固定开发 ID和商店正式 ID。没有正式 ID、可信代码签名和项目许可证确认时，只能视为候选包，不得标记为正式公开发布。
