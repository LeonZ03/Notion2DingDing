# Notion2DingDing

Notion2DingDing 是一个面向 Windows 的轻量迁移工具，用于把 Notion 页面转换为可编辑的钉钉富文本文档。

项目重点解决直接复制 Notion 内容时图片失效和复杂布局变成单列的问题：读取 Notion 官方 HTML 导出中的行列结构，把图片写入自包含 DOCX，再通过钉钉官方 `dws` 转换为在线文档，不把 Notion 临时图片 URL 留在目标文档中。

目前已经提供 Windows 一键使用界面和 Edge Manifest V3 扩展。Windows 界面可选择或拖入 Notion 导出包、识别标题、浏览或搜索钉钉文件夹并完成迁移；Edge 扩展通过 Native Messaging 调用同一个已安装核心，并提供导出包只读预检、分阶段进度、安全取消、错误恢复和结果链接，不复制转换或钉钉写入逻辑。Edge 当前页识别只用于完整性和选包对照提示，迁移标题与内容仍以 Notion 官方 HTML 导出 ZIP 为准。

## 正式版安装流程

正式发布后的推荐流程是：

1. 从 Microsoft Edge Add-ons 获取扩展。
2. 第一次打开扩展时，点击其中的“下载并安装”。
3. 运行一次 `Notion2DingDing-Setup.exe`；安装器在当前 Windows 用户范围内安装本地迁移核心和 Native Messaging Host，并在缺少时通过 winget/npm 安装固定依赖。
4. 完全重启 Edge，在扩展中完成一次钉钉登录和保存位置选择。
5. 此后日常迁移只需使用 Edge 扩展；版本不兼容时扩展会显示“下载最新版”。

Edge 不会代替扩展安装本机 Native Messaging 程序，因此首次使用是“Edge 扩展 + Windows 本地助手”两步；完成后不需要日常打开终端或本地程序。详细位置、升级和卸载方法见 [正式版安装说明](docs/release-installation.md)，数据处理方式见 [隐私说明](PRIVACY.md)。

v0.1.0 采用未签名 Windows 安装器先行发布：首次运行时 SmartScreen 可能要求选择“更多信息 → 仍要运行”。仅应从本项目官方 GitHub Release 下载，并先核对同页 `checksums.sha256`；Edge 商店扩展包仍由 Microsoft Edge Add-ons 签名和审核。后续版本计划接入受信任的 Windows 代码签名。

## 从源码安装到当前 Windows 用户

安装不需要管理员权限，也不会写系统级注册表。先克隆仓库，然后运行：

```powershell
git clone git@github.com:LeonZ03/Notion2DingDing.git
cd Notion2DingDing
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-local-tool.ps1
```

程序安装到 `%LOCALAPPDATA%\Programs\Notion2DingDing`，配置和最小幂等状态位于 `%LOCALAPPDATA%\Notion2DingDing`。安装完成后，在 Windows 开始菜单搜索并打开 `Notion2DingDing`；日常转换不需要打开终端。

## 一键界面（推荐）

1. 在 Notion 页面右上角选择“导出”，格式只选择 `HTML`，并保留文件和图片。当前版本不接受 `Markdown & CSV`。
2. 从 Windows 开始菜单打开 `Notion2DingDing`。
3. 选择导出的 ZIP 或解压目录，也可以直接把它拖进窗口。
4. 界面会从导出包内的 Notion 根页面自动填写文档标题；确认标题，需要时可直接修改。
5. 首次使用点击“选择钉钉文件夹”，可在“我的文件”或企业文档空间中逐层展开，也可直接按文件夹名称搜索；配置会自动保存。
6. 选择子页面处理方式。默认“在同页面内展开”；需要每页独立文档时选择“递归文档树”。
7. 点击“开始转换”。
8. 成功后点击界面中的链接，直接打开生成的钉钉文档或递归树的根文档。

界面内提供“检查环境”和“登录钉钉”入口。普通用户不需要执行 `n2dd config`、`n2dd migrate` 或测试命令；下面的 CLI 说明只用于自动化和排查问题。

如果已经安装，从最新仓库代码升级：

```powershell
git pull
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-local-tool.ps1 -Action Upgrade
```

### CLI 与故障排查（可选）

安装后仍会在 `%LOCALAPPDATA%\Microsoft\WindowsApps` 创建项目管理的 `n2dd.cmd`，供自动化和排查问题使用。

#### 1. 检查外部依赖

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

Go、Microsoft Edge 和 Native Messaging 只在构建或使用 Edge 扩展时需要，不是 Windows 一键界面和 CLI 的前置条件。

#### 2. 保存默认钉钉目标

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

#### 3. 从 Notion 导出

在 Notion 页面右上角选择“导出”，格式只选择 `HTML`，并保留文件和图片。可以把下载的 ZIP 直接交给工具，也可以先解压；`Markdown & CSV` 会被明确拒绝，因为它不包含可靠的多栏布局信息。

#### 4. 登录钉钉

```powershell
dws auth login
dws auth status --format json
```

登录凭据由 `dws` 和 Windows 当前用户凭据存储管理，不需要写进本仓库。

#### 5. 一条命令迁移

```powershell
n2dd migrate `
  --input "C:\path\to\notion-export.zip" `
  --name "迁移后的文档标题"
```

默认把所有子页面追加到同一篇文档。需要递归创建“同名文件夹 → 同名钉钉文档”时增加：

```powershell
n2dd migrate `
  --input "C:\path\to\notion-export.zip" `
  --name "迁移后的根页面标题" `
  --subpages tree
```

未保存默认目标时，可以继续在迁移命令中显式使用 `--folder` 或 `--workspace`，两种目标必须且只能选择一个。工具会从本地链接自动推断根页面并递归追加可达子页面；只有导出包包含多个独立根页面时，才需要用相对于导出包根目录的路径指定入口：

```powershell
n2dd migrate `
  --input "C:\path\to\notion-export.zip" `
  --entry "目标页面.html" `
  --folder "<TARGET_FOLDER_NODE_ID>"
```

命令会显示登录预检、资源检查、转换、导入和回读进度。默认 `--subpages inline`：根页面标题只作为钉钉文档标题，子页面追加为 H2，原入口合并成可在同文档跳转的原生目录。`--subpages tree`：工具先识别保存文件夹属于 Workspace 还是钉盘，再为每个 Notion 页面创建同名容器文件夹并导入同名钉钉文档；原页面入口二次回填为对应钉钉文档 URL，结果链接指向根文档。代码块、待办、分栏和图片仍逐页走同一转换、原生块恢复和回读流程。只有全部页面、链接和清理通过才会报告成功。

如果钉钉已经返回文档 URL，但网络中断或回读暂时不通过，使用完全相同的命令再次运行时只会恢复转换校验和远端回读，不会再次导入。回读图片计数会忽略钉钉生成的内联 SVG 装饰，只核对真正的远端图片；目标文件夹已有同名文档时，结果会明确报告钉钉添加的数字后缀。

CLI 对相同输入、标题和目标默认复用已有成功记录。明确需要新建副本时使用 `--force`；它会忽略以前的成功或写入未知记录并创建新文档，但仍不会绕过本地临时数据清理失败。

最终 JSON 还会给出源页面与子页面清单、SHA-256、图片引用数、本地文件数、去重后资源数、DOCX 输出数量，以及特殊块的映射或降级警告。中间 DOCX、解压目录和图片副本会在命令结束前永久删除（不进入回收站）；只有删除并验证通过后才会报告成功。

#### 6. 卸载

在仓库目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-local-tool.ps1 -Action Uninstall
```

卸载只删除带本项目所有权标记的程序目录、`n2dd.cmd`、配置和最小幂等状态。它不会删除 Notion 导出包、已生成的钉钉文档、dws 登录凭据或其他文件；遇到同名但不属于本项目的文件时会拒绝删除。

## 本地验收

仓库提供了不包含真实用户数据的固定夹具：

```powershell
npm run check:stage4
```

该命令会回归阶段 1、阶段 2，并验证普通、长篇、多图片和嵌套子页面夹具：

- 标题、正文、列表、表格和固定文本存在；
- 两张测试图片都位于 DOCX 内部；
- 没有外部图片关系；
- 没有 Notion 临时图片 URL。
- 成功导入后必须用真实文档 URL 回读；
- 图片缺失、ZIP 损坏、未登录和无权限不能误报成功；
- 写入状态未知时不自动重试；用户确认接受可能产生重复文档后，可明确选择再次导出。
- 成功、确定失败和写入状态未知时，中间 DOCX 与任务目录均已永久删除；测试结束后也不留下内容型产物。
- 幂等状态只保留任务哈希、目标、远端标识和检查结论，不保存正文、图片、文件名、输入路径或 DOCX 路径。
- 中文、空格、URL 编码路径和两层子页面可正确处理；
- 子页面入口会合并为一个钉钉原生目录，目录项逐一核对子页面标题与 H2 块 ID；更新或旧入口删除状态未知时只恢复原文档，不重复导入；
- 可选递归文档树会为根页、子页和孙页分别创建同名文件夹与独立文档，回填跨文档链接；相同任务复跑不重复创建目录或文档；
- 八个图片引用可按 SHA-256 去重，并核对全部八个输出位置；
- Callout、Toggle 和数据库生成明确映射或降级报告；
- 三张图片并排，以及图片与表格同排，可保留同一行、列数和相对列宽；
- 代码块会从 DOCX `SourceCode` 段落恢复为钉钉原生 `code` 块，并核对正文、换行、缩进和语言；
- 根页面标题只保留为钉钉文档标题，DOCX 中不得存在额外 `Title` 或同名根 `Heading1`；子页面标题仍需存在；
- 原生代码块或待办更新状态未知时，二次执行只恢复既有文档，不重复导入；
- 长篇夹具的开头、中间、末尾与规模指标均通过检查。

## Edge 扩展

```text
Edge 扩展
    │ Native Messaging
    ▼
Windows 本地迁移核心
    ├─ 读取官方 HTML 导出包
    ├─ 下载、缓存并校验图片
    ├─ 调用成熟工具转换文档
    └─ 调用 dws 导入钉钉富文本文档
```

Edge 扩展负责识别当前 Notion 页面、选择“在同页面内展开（默认）”或“递归文档树”、显示钉钉登录状态和保存位置、选择官方 HTML 导出 ZIP，以及展示迁移结果；长页面和懒加载内容无法从当前 DOM 保证完整，因此不会把当前页 DOM 直接当作迁移输入。选择 ZIP 后扩展只解包预检，显示包内根页面标题、导出时间和页面数量，并用包内标题填入可编辑标题框；此时不会转换或写入钉钉，必须再次点击“开始转换”。

选择 ZIP 后，弹窗会用内容哈希和当前保存位置查找最小迁移记录：若确认此前已导出，会显示状态和真实钉钉链接，主按钮改为“仍再次导出”；若以前的写入只是不确定但记录中已有链接，则提示“此前可能已导出”，同时允许“再次导出为新文档”。只有用户点击该按钮后，弹窗才按预检、转换、导入、回读、清理五个阶段显示实时进度。关闭再打开弹窗会从当前浏览器会话恢复任务状态；只有在钉钉写入开始前才允许取消，取消后必须确认本地暂存已清理。

扩展中的“登录 / 重新登录”和“选择 / 更改位置”会通过 Native Messaging 打开已安装的 Windows 工具；读取钉钉目录期间会显示等待提示并阻止重复点击。登录凭据和目标 ID 不进入扩展。权限限制为 `activeTab`、`scripting`、`nativeMessaging` 和 `storage`：`storage` 只在会话型 `chrome.storage.session` 中保存当前 Native Host 任务 ID和稳定 Notion 页面 ID，不保存导出包、标题、正文、图片、钉钉凭据或目标 ID。扩展不启动 localhost 服务。

扩展图标根据用户提供的 Notion 与钉钉品牌参考图重新组合，提供 `16/32/48/128px`；相关商标和品牌图形权利仍归各自权利人，本项目仅用于说明兼容迁移关系，不表示两家产品对本项目的背书。正式公开发布前还需在阶段 7 复核两家的品牌使用规范。弹窗采用紧凑的内容优先布局，并覆盖加载、禁用、迁移、取消、错误、未知状态和成功结果。

Notion 当前公开 API 没有“导出当前页面为 HTML ZIP”的接口。公开 API 可读取页面、块或 Markdown，但不能稳定返回官方 HTML 导出中的 `column-list`、列宽和完整本地资源，因此扩展不会使用私有接口、Cookie 或模拟点击代替官方导出。请在 Notion 页面右上角选择“••• → 导出 → HTML”，再把 ZIP 交给扩展。

开发模式安装：

```powershell
# 构建扩展与 Native Host，并注册到当前 Windows 用户
npm run build:extension
npm run install:native

# 在 Edge 的 edge://extensions 中启用开发人员模式，加载此目录
dist\edge-extension
```

固定开发扩展 ID 为 `hheldkapioofhdbblmgfokdnpgfgaafo`；Native Host 清单只允许该扩展来源。加载后，弹窗应显示 Host 版本、`windows/amd64`、阶段 4 本地核心状态、钉钉登录状态和当前保存位置。常用诊断与卸载命令：

```powershell
npm run status:native
npm run doctor:native
npm run upgrade:native
npm run uninstall:native
```

## 常用检查

```powershell
# 当前完整链路（包含阶段 1–6 回归）
npm run check:stage6

# 阶段 7 发布候选包、兼容检查和隔离安装/卸载
npm run check:stage7

# 构建到 dist/release/v<版本>
npm run build:release

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
  edge-extension/   Edge Manifest V3 扩展
  native-host/      Go Native Messaging Host
docs/               架构、工具选型和开发文档
protocol/           扩展与 Native Host 的版本化消息协议
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

- 钉钉文件夹选择器可读取当前 DWS profile 有权访问的“我的文件”和企业文档空间；不属于这些根目录但能被当前账号搜索到的旧钉盘/独立空间文件夹，也可按名称直接选择。无权访问的文件夹不会被强行展示。
- 子页面默认按链接顺序追加到同一篇钉钉文档，并生成原生目录；可选“递归文档树”会创建“页面同名文件夹 + 同名独立文档”。由于钉钉文档节点本身不能直接充当父文件夹，树模式会多一层同名文件夹容器。
- Toggle 会展开为普通内容；HTML 内嵌表格会保留，单独的数据库 CSV 链接仍只生成降级说明。
- 普通单图和单列容器不会生成 1×1 表格；Notion 官方 HTML 的 Figure 会转为普通图片段落。
- 两列及以上多栏在 DOCX 中先使用带 `Notion Columns` 专用样式的无边框布局表保留行列关系，导入后会核对该样式、数量和列数，再安全恢复为钉钉原生分栏（`sr:true`），让外围不再按普通表格显示；普通数据表不参与更新。复杂内容会使用横向 DOCX 页面以减少挤压，最终钉钉显示仍需以实际导入结果为准。
- 图片总体积可能超过钉钉 DOCX 导入上限时，工具会在临时目录中自动优化较大的 PNG，源导出包保持不变；自动优化后仍超过 20 MiB 会在写入前明确停止。
- Notion 书签卡片会保留链接和文字；若站点图标或缩略图仍是未随官方导出包下载的外部 URL，工具会明确记录降级并省略这些装饰图片，不会联网抓取。正文或 Figure 中的外部图片仍会在写入前被拒绝。
- 普通附件当前只保留明确降级说明，不会自动上传为钉钉附件。
- Edge 当前页模式只读取页面标题和可见块/图片规模，用于提示 DOM 不完整并与所选导出包对照；可编辑迁移标题默认从 ZIP 内根页面识别。由于 Notion 没有官方 HTML 导出 API，扩展不直接迁移当前 DOM，仍需选择不超过 46 MiB 的官方 HTML 导出 ZIP；更大的导出包请使用 Windows 一键工具。
- 当前安装方式仍需先克隆或下载仓库；独立安装包和自动更新将在发布阶段提供。

使用和错误契约见 [docs/migration-contract.md](docs/migration-contract.md)，详细内容映射见 [docs/content-mapping.md](docs/content-mapping.md)，开发细节见 [docs/development.md](docs/development.md)，工具选型见 [docs/tooling.md](docs/tooling.md)。
