# Notion2DingDing

Notion2DingDing 是一个面向 Windows 的轻量迁移工具，用于把 Notion 页面转换为可编辑的钉钉富文本文档。

项目重点解决直接复制 Notion 内容时图片失效的问题：先把图片写入自包含 DOCX，再通过钉钉官方 `dws` 转换为在线文档，不把 Notion 临时图片 URL 留在目标文档中。

目前已经可以在 Windows 本地用一条命令完成“Notion Markdown 导出包 → 自包含 DOCX → 钉钉在线文档 → 回读验收”。Edge 一键迁移将在本地工具稳定后继续开发。

## 安装到当前 Windows 用户

安装不需要管理员权限，也不会写系统级注册表。先克隆仓库，然后运行：

```powershell
git clone git@github.com:LeonZ03/Notion2DingDing.git
cd Notion2DingDing
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-local-tool.ps1
```

程序安装到 `%LOCALAPPDATA%\Programs\Notion2DingDing`，配置和最小幂等状态位于 `%LOCALAPPDATA%\Notion2DingDing`，并在 `%LOCALAPPDATA%\Microsoft\WindowsApps` 创建项目管理的 `n2dd.cmd`。重新打开终端后可以直接使用 `n2dd`。

如果已经安装，从最新仓库代码升级：

```powershell
git pull
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-local-tool.ps1 -Action Upgrade
```

### 1. 检查外部依赖

需要：

- Windows 10/11
- Node.js 24+ 与 npm 11+
- [Pandoc](https://pandoc.org/installing.html)，当前验证版本为 `3.8.2.1`
- 钉钉官方开源工具 [DingTalk Workspace CLI](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli)

安装主程序后运行：

```powershell
n2dd doctor
```

`doctor` 会检查 Windows、Node.js、Pandoc、`dws` 和钉钉登录状态，并在缺失时返回可直接执行的修复命令。常用安装命令如下：

```powershell
winget install OpenJS.NodeJS
winget install JohnMacFarlane.Pandoc
npm install -g dingtalk-workspace-cli@1.0.59
dws auth login
```

Go、Microsoft Edge 和 Native Messaging 只在后续插件开发时需要，不是当前本地转换流程的前置条件。

### 2. 保存默认钉钉目标

保存常用文件夹后，日常迁移不必重复输入 `nodeId`：

```powershell
n2dd config --folder "<TARGET_FOLDER_NODE_ID>"
```

知识库目标使用：

```powershell
n2dd config --workspace "<WORKSPACE_ID>"
```

如果使用指定的 dws profile，可在配置命令末尾增加 `--profile "<PROFILE>"`。查看或清除配置：

```powershell
n2dd config --show
n2dd config --clear
```

### 3. 从 Notion 导出

在 Notion 页面右上角选择“导出”，格式选择 `Markdown & CSV`，并保留文件和图片。可以把下载的 ZIP 直接交给转换脚本，也可以先解压。

### 4. 登录钉钉

```powershell
dws auth login
dws auth status --format json
```

登录凭据由 `dws` 和 Windows 当前用户凭据存储管理，不需要写进本仓库。

### 5. 一条命令迁移

```powershell
n2dd migrate `
  --input "C:\path\to\notion-export.zip" `
  --name "迁移后的文档标题"
```

未保存默认目标时，可以继续在迁移命令中显式使用 `--folder` 或 `--workspace`，两种目标必须且只能选择一个。工具会从本地链接自动推断根页面并递归追加可达子页面；只有导出包包含多个独立根页面时，才需要用相对于导出包根目录的路径指定入口：

```powershell
n2dd migrate `
  --input "C:\path\to\notion-export.zip" `
  --entry "目标页面.md" `
  --folder "<TARGET_FOLDER_NODE_ID>"
```

命令会显示登录预检、资源检查、转换、导入和回读进度。只有真实文档 URL 回读通过后才会报告成功，并返回 `documentUrl`；图片缺失、ZIP 损坏、未登录、无写入权限或回读不完整都会明确失败。

相同输入、标题和目标默认复用已有成功记录，避免重复创建文档。只有明确需要新建副本时才使用 `--force`；写入结果未知时即使指定 `--force` 也不会自动重试。

最终 JSON 还会给出源页面与子页面清单、SHA-256、图片引用数、本地文件数、去重后资源数、DOCX 输出数量，以及特殊块的映射或降级警告。中间 DOCX、解压目录和图片副本会在命令结束前永久删除（不进入回收站）；只有删除并验证通过后才会报告成功。

### 6. 卸载

在仓库目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-local-tool.ps1 -Action Uninstall
```

卸载只删除带本项目所有权标记的程序目录、`n2dd.cmd`、配置和最小幂等状态。它不会删除 Notion 导出包、已生成的钉钉文档、dws 登录凭据或其他文件；遇到同名但不属于本项目的文件时会拒绝删除。

## 本地验收

仓库提供了不包含真实用户数据的固定夹具：

```powershell
npm run check:stage3
```

该命令会回归阶段 1、阶段 2，并验证普通、长篇、多图片和嵌套子页面夹具：

- 标题、正文、列表、表格和固定文本存在；
- 两张测试图片都位于 DOCX 内部；
- 没有外部图片关系；
- 没有 Notion 临时图片 URL。
- 成功导入后必须用真实文档 URL 回读；
- 图片缺失、ZIP 损坏、未登录和无权限不能误报成功；
- 写入状态未知时禁止自动重试。
- 成功、确定失败和写入状态未知时，中间 DOCX 与任务目录均已永久删除；测试结束后也不留下内容型产物。
- 幂等状态只保留任务哈希、目标、远端标识和检查结论，不保存正文、图片、文件名、输入路径或 DOCX 路径。
- 中文、空格、URL 编码路径和两层子页面可正确处理；
- 八个图片引用可按 SHA-256 去重，并核对全部八个输出位置；
- Callout、Toggle、多栏和数据库生成明确映射或降级报告；
- 长篇夹具的开头、中间、末尾与规模指标均通过检查。

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
# 当前本地迁移工具（包含阶段 1–4 回归）
npm run check:stage4

# 隔离环境安装、诊断、迁移、升级与卸载测试
npm run test:stage4

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
- 工具创建的中间文件在成功、失败和未知状态下都会永久删除，不经过 Windows 回收站；清理失败会明确报错，不能误报迁移成功。
- 用户传入的 Notion 导出 ZIP 或目录不会被自动删除；它属于源数据，是否删除必须由用户另行明确决定。
- 建议只授予 `dws` 完成迁移所需的文档业务域权限。

## 当前限制

- 目标钉钉文件夹需要手工提供 `nodeId`，或者提供知识库 `workspaceId`；图形化目标选择尚未实现。
- 子页面会按链接顺序追加到同一篇钉钉文档，不会还原为独立的钉钉页面树。
- Toggle 会展开为普通引用文本，数据库会降级为 CSV 说明，多栏会按导出顺序线性排列。
- 普通附件当前只保留明确降级说明，不会自动上传为钉钉附件。
- Edge 当前页读取与 Native Messaging 真实链路尚未接入。
- 当前安装方式仍需先克隆或下载仓库；独立安装包和自动更新将在发布阶段提供。

使用和错误契约见 [docs/migration-contract.md](docs/migration-contract.md)，详细内容映射见 [docs/content-mapping.md](docs/content-mapping.md)，开发细节见 [docs/development.md](docs/development.md)，工具选型见 [docs/tooling.md](docs/tooling.md)。
