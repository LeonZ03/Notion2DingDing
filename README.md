# Notion2DingDing

Notion2DingDing 是一个面向 Windows 的轻量迁移工具，目标是在 Microsoft Edge 中一键将当前 Notion 页面转换为可编辑的钉钉富文本文档。

它重点解决直接复制 Notion 内容时图片失效的问题：迁移过程会先获取并校验图片，再把图片作为钉钉文档资源重新上传，不会把 Notion 的临时图片 URL 留在目标文档中。

> 当前项目处于早期开发阶段。Edge 扩展和 Windows 本地助手的基础骨架已经建立，真实的 Notion 读取与钉钉写入尚未开放使用。

## 预期使用方式

完成后的主要流程是：

1. 在 Edge 中打开需要迁移的 Notion 页面。
2. 点击 Notion2DingDing 扩展图标。
3. 选择目标钉钉知识库或文件夹。
4. 点击“迁移到钉钉”。
5. 等待迁移完成，打开生成的钉钉富文本文档。

对于超长页面或 Notion 页面结构发生变化的情况，工具还会提供“导入 Notion 导出包”作为可靠回退方式。

## 工作方式

```text
Edge 扩展
    │ Native Messaging
    ▼
Windows 本地助手
    ├─ 读取 Notion 页面或导出包
    ├─ 下载、缓存并校验图片
    ├─ 转换文档结构
    └─ 调用 DWS 导入钉钉富文本文档
```

Edge 扩展只负责用户界面和任务状态。本地助手负责文件转换、图片处理和钉钉登录态隔离。两部分通过 Edge Native Messaging 通信，不会开放本地 HTTP 端口。

## 开发环境

当前项目以 Windows 原生环境为主，不需要 WSL2。

需要：

- Windows 10/11
- Microsoft Edge
- Node.js 24+
- npm 11+
- Go 1.22+
- Pandoc
- DingTalk Workspace CLI（接入真实钉钉文档时需要）

## 运行开发版本

### 1. 安装依赖并构建扩展

```powershell
npm install
npm run check:extension
```

构建结果位于：

```text
dist/edge-extension
```

### 2. 构建 Windows 本地助手

```powershell
npm run check:native
npm run build:native
```

构建结果位于：

```text
dist/native-host/notion2dingding-host.exe
```

### 3. 在 Edge 中加载扩展

1. 打开 `edge://extensions`。
2. 启用“开发人员模式”。
3. 点击“加载解压缩的扩展”。
4. 选择 `dist/edge-extension`。
5. 复制 Edge 显示的扩展 ID。

### 4. 注册本地助手

```powershell
.\scripts\install-native-host.ps1 -ExtensionId "<EDGE_EXTENSION_ID>"
```

重新打开扩展弹窗。如果注册成功，扩展会显示本地助手版本和运行平台。

更完整的开发操作见 [docs/development.md](docs/development.md)。

## 常用检查

```powershell
# Edge 扩展类型检查、构建和测试
npm run check:extension

# Go 本地助手测试
npm run check:native

# 全部检查
npm run check:all
```

## 仓库结构

```text
apps/
  edge-extension/   Edge Manifest V3 扩展
  native-host/      Windows Native Messaging 本地助手
docs/               架构和开发文档
protocol/           扩展与本地助手的消息协议
scripts/            Windows 构建与注册脚本
tests/              自动化测试
```

## 安全与隐私

- 不把 Notion 临时图片 URL 写入钉钉文档。
- 不在扩展源码或仓库中保存 Notion、钉钉 Token、AppKey 或 AppSecret。
- Native Messaging Host 只允许明确注册的扩展 ID 调用。
- 钉钉登录态交给 DWS 和操作系统凭据存储管理。
- 中间文件和图片缓存在本机处理，不会默认上传到第三方服务。

## 当前限制

- 尚未实现真实 Notion 页面迁移。
- 尚未完成 DWS 钉钉富文档导入验证。
- 当前只提供 Native Messaging 健康检查界面。
