# Notion2DingDing

Notion2DingDing 是一个面向 Windows 的轻量迁移工具，用于把 Notion 页面转换为可编辑的钉钉富文本文档。

项目重点解决直接复制 Notion 内容时图片失效的问题：先把图片写入自包含 DOCX，再通过钉钉官方 `dws` 转换为在线文档，不把 Notion 临时图片 URL 留在目标文档中。

目前已经可以在 Windows 本地完成“Notion Markdown 导出包 → DOCX → 钉钉在线文档”的验证流程。Edge 一键迁移将在本地工具稳定后继续开发。

## 当前使用方式

### 1. 准备环境

需要：

- Windows 10/11
- Node.js 24+ 与 npm 11+
- [Pandoc](https://pandoc.org/installing.html)，当前验证版本为 `3.8.2.1`
- 钉钉官方开源工具 [DingTalk Workspace CLI](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli)

```powershell
npm install
npm install -g dingtalk-workspace-cli@1.0.59
```

Go、Microsoft Edge 和 Native Messaging 只在后续插件开发时需要，不是当前本地转换流程的前置条件。

### 2. 从 Notion 导出

在 Notion 页面右上角选择“导出”，格式选择 `Markdown & CSV`，并保留文件和图片。可以把下载的 ZIP 直接交给转换脚本，也可以先解压。

### 3. 转换为自包含 DOCX

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\convert-notion-export.ps1 `
  -InputPath "C:\path\to\notion-export.zip" `
  -OutputPath ".\artifacts\notion-output.docx"
```

如果导出包中包含多个 Markdown 页面，需要用相对于导出包根目录的路径指定入口：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\convert-notion-export.ps1 `
  -InputPath "C:\path\to\notion-export.zip" `
  -EntryPath "目标页面.md" `
  -OutputPath ".\artifacts\notion-output.docx"
```

脚本会检查 DOCX 图片关系，发现外部图片关系或 Notion 临时图片地址时直接失败。

### 4. 导入钉钉文档

首次使用先完成钉钉官方 OAuth 登录：

```powershell
dws auth login
dws auth status --format json
```

当前版本需要提供目标钉钉文件夹的 `nodeId`：

```powershell
dws doc +import `
  --file artifacts/notion-output.docx `
  --folder "<TARGET_FOLDER_NODE_ID>" `
  --name "迁移后的文档标题" `
  --format json
```

成功结果会包含 `taskId` 和 `documentUrl`。请打开返回的文档链接核对正文和图片。

## 本地验收

仓库提供了不包含真实用户数据的固定夹具：

```powershell
npm run check:stage1
```

该命令会分别验证目录和 ZIP 输入，并检查：

- 标题、正文、列表、表格和固定文本存在；
- 两张测试图片都位于 DOCX 内部；
- 没有外部图片关系；
- 没有 Notion 临时图片 URL。

## 后续产品形态

```text
Edge 扩展
    │ Native Messaging
    ▼
Windows 本地迁移核心
    ├─ 读取当前 Notion 页面或导出包
    ├─ 下载、缓存并校验图片
    ├─ 调用成熟工具转换文档
    └─ 调用 dws 导入钉钉富文本文档
```

Edge 扩展最终只负责页面入口、参数选择、进度和结果展示，继续复用同一个本地迁移核心，不重新实现转换逻辑。

## 常用检查

```powershell
# 当前本地导出转换链路
npm run check:stage1

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
  edge-extension/   Edge Manifest V3 扩展，当前暂缓功能开发
  native-host/      本地迁移核心与未来 Native Messaging Host
docs/               架构、工具选型和开发文档
protocol/           未来扩展与本地助手的消息协议
scripts/            Windows 转换、构建与注册脚本
tests/              脱敏夹具和自动化测试
```

## 安全与隐私

- 不把 Notion 临时图片 URL 写入钉钉文档。
- 不在源码或仓库中保存 Notion、钉钉 Token、AppKey 或 AppSecret。
- 钉钉登录态由 `dws` 和 Windows 当前用户凭据存储管理。
- 中间文件和图片在本机处理，不会默认上传到钉钉以外的第三方服务。
- 建议只授予 `dws` 完成迁移所需的文档业务域权限。

## 当前限制

- 当前仍是阶段性本地流程，还没有“一条命令完成转换和导入”的正式 CLI。
- 目标钉钉文件夹需要手工提供 `nodeId`，目标选择将在下一阶段实现。
- 多页面、数据库、Callout、Toggle、多栏和复杂代码块的映射尚未完成系统验收。
- Edge 当前页读取与 Native Messaging 真实链路尚未接入。
- 钉钉图片的 24 小时持久性复查尚未完成。

开发细节见 [docs/development.md](docs/development.md)，工具选型见 [docs/tooling.md](docs/tooling.md)。
