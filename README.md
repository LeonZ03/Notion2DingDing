# Notion2DingDing

Notion2DingDing 是一个面向 Windows 的 Notion → 钉钉文档迁移工具。它读取 Notion 官方导出的 HTML ZIP，将页面内容转换为可编辑的钉钉富文本文档，并尽量保留原页面的结构与阅读体验。

项目通过 Edge 扩展提供日常入口，转换和钉钉写入由本地助手完成；也可以直接从本仓库安装 Windows 一键界面，不使用 Edge 扩展。

> 本项目是独立迁移工具，与 Notion、钉钉和 Microsoft Edge 官方无隶属、联合或背书关系。相关商标与品牌图形权利归各自权利人所有。

## 功能亮点

- **可编辑的钉钉文档**：迁移结果是钉钉原生富文本文档，不是只读预览或普通附件。
- **图片持久化**：图片随导出包在本地处理并写入目标文档，不依赖可能过期的 Notion 临时图片地址。
- **复杂内容处理**：支持标题、段落、列表、表格、代码块、待办、Callout、Toggle、图片和多栏布局。
- **两种子页面方式**：默认在同一文档内展开并生成目录，也可以递归创建文件夹和独立钉钉文档。
- **转换前预检**：选择 ZIP 后先展示识别出的标题、导出时间和页面数量，确认后才会写入钉钉。
- **结果可验证**：迁移结束后回读钉钉文档，并提供可直接打开的真实文档链接。
- **重复导入可控**：发现已有迁移记录时展示原钉钉链接，同时允许用户明确选择再次导出。
- **本地隐私保护**：凭据不进入扩展或仓库；工具生成的解压目录、图片副本和 DOCX 会在任务结束时清理。

## 使用方式一：从 Edge 安装（正式版）

适合希望日常从浏览器直接操作的用户。

### 首次安装

1. 在 Microsoft Edge Add-ons 中搜索并安装 **Notion2DingDing**。
2. 第一次打开扩展时，按照提示下载并运行 `Notion2DingDing-Setup.exe`。
3. 安装完成后完全关闭并重新打开 Edge。
4. 打开扩展，完成一次钉钉登录并选择默认保存位置。

Edge 扩展当前正在 Microsoft 审核；正式上架后将在这里补充商店直达链接。本地助手也可以从 [GitHub Releases](https://github.com/LeonZ03/Notion2DingDing/releases) 下载。

v0.1.0 的 Windows 安装器尚未进行代码签名，SmartScreen 可能提示“Windows 已保护你的电脑”。请只从本项目 GitHub Release 下载，核对同页 `checksums.sha256` 后选择“更多信息 → 仍要运行”。

### 迁移文档

1. 在 Notion 页面右上角选择“导出”。
2. 导出格式选择 **HTML**；需要子页面时打开“包含子页面”。
3. 打开 Edge 扩展，选择刚下载的 HTML ZIP。
4. 核对扩展识别出的标题、导出时间和页面数量；标题可以修改。
5. 选择“同页展开”或“递归文档树”，然后点击“开始转换”。
6. 转换完成后，点击结果链接打开钉钉文档。

Notion 当前没有公开的官方 HTML 导出 API，因此扩展不能代替用户导出 ZIP。扩展对当前 Notion 页面进行识别和选包核对，实际迁移内容始终以官方 HTML 导出包为准。

## 使用方式二：从仓库本地部署

适合希望直接运行 Windows 一键界面、参与开发，或者暂时不使用 Edge 商店版的用户。

### 环境要求

- Windows 10 或 Windows 11
- Node.js 24+ 和 npm 11+
- [Pandoc](https://pandoc.org/installing.html)
- 钉钉官方开源工具 [DingTalk Workspace CLI](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli)

### 安装

在 PowerShell 中运行：

```powershell
git clone https://github.com/LeonZ03/Notion2DingDing.git # 下载项目源码
cd Notion2DingDing                                      # 进入项目目录
npm install                                             # 安装并锁定仓库所需的 Node.js 依赖
npm run install:local                                   # 安装当前用户级 Windows 一键界面和本地迁移工具
npm run doctor:local                                    # 检查 Node.js、Pandoc、dws 和钉钉登录状态
```

安装不需要管理员权限。完成后在 Windows 开始菜单搜索并打开 **Notion2DingDing**，即可选择或拖入 Notion HTML ZIP、登录钉钉、选择保存位置并开始迁移，不需要 Edge 扩展。

如果环境检查提示缺少依赖，可以运行：

```powershell
winget install OpenJS.NodeJS                            # 安装 Node.js
winget install JohnMacFarlane.Pandoc                    # 安装 Pandoc
npm install -g dingtalk-workspace-cli@1.0.59            # 安装项目已验证版本的钉钉 dws
dws auth login                                          # 在浏览器中完成钉钉授权登录
npm run doctor:local                                    # 重新检查本地环境和登录状态
```

### 更新与卸载

```powershell
git pull                                                # 拉取仓库最新代码
npm install                                             # 按 package-lock.json 同步依赖
npm run upgrade:local                                   # 升级已安装的 Windows 一键界面和本地工具
npm run uninstall:local                                 # 卸载本项目安装的本地程序、配置和最小状态
```

卸载不会删除用户选择的 Notion 导出包、已经生成的钉钉文档或 dws 登录凭据。

### 仓库检查（可选）

```powershell
npm run check                                           # 运行当前主链路的自动化检查
npm run check:extension                                 # 仅检查 Edge 扩展的类型、构建和测试
npm run check:native                                    # 仅构建并测试 Native Messaging Host
```

更多开发、构建和发布命令见 [开发文档](docs/development.md)。

## 当前支持与限制

- 当前仅支持 Windows 10/11。
- 输入必须是 Notion 官方 **HTML** 导出 ZIP 或解压目录，不支持 `Markdown & CSV` 导出。
- Edge 扩展选择的 ZIP 不得超过 46 MiB；更大的导出包请使用 Windows 一键界面。
- 普通附件和独立数据库 CSV 当前会给出明确的降级说明，不会静默丢失。
- Toggle 会展开为普通内容；复杂多栏会尽量恢复为钉钉原生分栏，最终效果仍受钉钉导入能力限制。
- 图片总体积接近钉钉导入限制时，工具可能在临时目录中优化较大的 PNG，但不会修改用户的源导出包。

详细内容映射见 [内容映射说明](docs/content-mapping.md)，常见行为与错误见 [迁移契约](docs/migration-contract.md)。

## 安全与隐私

- Notion、钉钉 Token、AppKey、AppSecret 和用户文档不会提交到本仓库。
- 钉钉登录态由 dws 和 Windows 当前用户凭据存储管理。
- 中间内容在本机处理，不会默认发送到钉钉以外的第三方服务。
- 工具创建的临时内容会在成功、失败和写入状态未知时清理；清理失败不会被报告为迁移成功。
- 用户提供的原始 Notion ZIP 或目录不会被工具自动删除。

完整说明见 [隐私政策](PRIVACY.md) 和 [第三方软件声明](THIRD_PARTY_NOTICES.md)。

## 项目结构

```text
apps/edge-extension/  Edge Manifest V3 扩展
apps/native-host/     Windows Native Messaging Host
scripts/              本地安装、迁移、构建与发布脚本
protocol/             扩展与本地助手的版本化协议
tests/                脱敏夹具和自动化测试
docs/                 使用、架构与开发文档
```
