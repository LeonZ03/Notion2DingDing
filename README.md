# Notion2DingDing

Notion2DingDing 是一个面向 Windows 的轻量迁移工具，用于把 Notion 页面转换为可编辑的钉钉富文本文档。

项目重点解决直接复制 Notion 内容时图片失效的问题：先把图片写入自包含 DOCX，再通过钉钉官方 `dws` 转换为在线文档，不把 Notion 临时图片 URL 留在目标文档中。

目前已经可以在 Windows 本地用一条命令完成“Notion Markdown 导出包 → 自包含 DOCX → 钉钉在线文档 → 回读验收”。Edge 一键迁移将在本地工具稳定后继续开发。

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

### 3. 登录钉钉

```powershell
dws auth login
dws auth status --format json
```

登录凭据由 `dws` 和 Windows 当前用户凭据存储管理，不需要写进本仓库。

### 4. 一条命令迁移

```powershell
npm run migrate -- `
  --input "C:\path\to\notion-export.zip" `
  --folder "<TARGET_FOLDER_NODE_ID>" `
  --name "迁移后的文档标题"
```

也可以用 `--workspace "<WORKSPACE_ID>"` 指定钉钉知识库，两种目标必须且只能选择一个。如果导出包中包含多个 Markdown 页面，再用相对于导出包根目录的路径指定入口：

```powershell
npm run migrate -- `
  --input "C:\path\to\notion-export.zip" `
  --entry "目标页面.md" `
  --folder "<TARGET_FOLDER_NODE_ID>"
```

命令会显示登录预检、资源检查、转换、导入和回读进度。只有真实文档 URL 回读通过后才会报告成功，并返回 `documentUrl`；图片缺失、ZIP 损坏、未登录、无写入权限或回读不完整都会明确失败。

相同输入、标题和目标默认复用已有成功记录，避免重复创建文档。只有明确需要新建副本时才使用 `--force`；写入结果未知时即使指定 `--force` 也不会自动重试。

## 本地验收

仓库提供了不包含真实用户数据的固定夹具：

```powershell
npm run check:stage2
```

该命令会回归阶段 1 的目录和 ZIP 转换，并验证阶段 2 的迁移编排：

- 标题、正文、列表、表格和固定文本存在；
- 两张测试图片都位于 DOCX 内部；
- 没有外部图片关系；
- 没有 Notion 临时图片 URL。
- 成功导入后必须用真实文档 URL 回读；
- 图片缺失、ZIP 损坏、未登录和无权限不能误报成功；
- 写入状态未知时禁止自动重试。

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
# 当前本地迁移 MVP（包含阶段 1 回归）
npm run check:stage2

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

- 目标钉钉文件夹需要手工提供 `nodeId`，或者提供知识库 `workspaceId`；图形化目标选择尚未实现。
- 多页面、数据库、Callout、Toggle、多栏和复杂代码块的映射尚未完成系统验收。
- Edge 当前页读取与 Native Messaging 真实链路尚未接入。
- 钉钉图片的 24 小时持久性复查尚未完成。

使用和错误契约见 [docs/migration-contract.md](docs/migration-contract.md)，开发细节见 [docs/development.md](docs/development.md)，工具选型见 [docs/tooling.md](docs/tooling.md)。
