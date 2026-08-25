# Windows 开发指南

## 0. 本地 CLI 安装与验收

阶段 4 的用户级 CLI 不依赖 Edge 或 Go。程序、数据和命令入口分离：

```text
%LOCALAPPDATA%\Programs\Notion2DingDing   程序文件与所有权标记
%LOCALAPPDATA%\Notion2DingDing            配置与最小幂等状态
%LOCALAPPDATA%\Microsoft\WindowsApps\n2dd.cmd
```

```powershell
npm run install:local
n2dd doctor
n2dd config --folder "<TARGET_FOLDER_NODE_ID>"
n2dd migrate --input "C:\path\to\notion-export.zip"
npm run upgrade:local
npm run uninstall:local
```

安装和升级只复制迁移所需的 5 个运行时脚本，不复制夹具、源码历史或 `node_modules`。升级先构建同级暂存目录，再替换带所有权标记的旧程序目录；配置与最小状态独立保留。卸载在删除前校验程序、数据和启动器标记，不修改 PATH 或系统级注册表。

隔离验收：

```powershell
npm run test:stage4
```

该测试在系统临时目录模拟全新用户根目录，完成安装、依赖缺失/就绪诊断、配置、夹具迁移、升级、卸载和防误删检查，最后永久删除整个测试根目录。

## 1. 扩展

```powershell
npm install
npm run check:extension
```

打开 `edge://extensions`：

1. 启用“开发人员模式”。
2. 点击“加载解压缩的扩展”。
3. 选择 `dist/edge-extension`。
4. 复制扩展 ID。

## 2. 本地助手

安装 Go 1.22 或更高版本后：

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
.\scripts\install-native-host.ps1 -ExtensionId "<EDGE_EXTENSION_ID>"
```

脚本执行以下操作：

- 将助手复制到 `%LOCALAPPDATA%\Notion2DingDing`
- 生成只允许指定扩展 ID 的 Host Manifest
- 写入当前用户的 Edge Native Messaging Host 注册表项

重新打开扩展弹窗，状态应显示本地助手版本和 `windows/amd64`。

## 4. 钉钉依赖

真实迁移功能接入前，需要安装并登录 DingTalk Workspace CLI：

```powershell
dws auth login
dws auth status --format json
```

本地开发不在仓库中保存 DWS Token、AppKey 或 AppSecret。
