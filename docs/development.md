# Windows 开发指南

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
