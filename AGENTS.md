# AGENTS.md

## 项目使命

Notion2DingDing 将 Notion 页面迁移为可编辑的钉钉富文本文档。最终产品形态是一个操作简单的 Microsoft Edge Manifest V3 扩展，配套一个 Windows Native Messaging 本地助手。

迁移成功的核心标准不是“文字复制过去了”，而是：正文结构可编辑、图片由钉钉持久托管、迁移结果可验证、失败可恢复、重复执行不会无提示地产生重复文档。

## 产品契约

- 目标必须是钉钉原生富文本文档，不是钉盘附件、聊天消息或只读预览。
- 不得把 Notion 托管文件的临时签名 URL 作为最终图片地址。
- 默认工作流是“打开 Notion 页面 → 点击扩展 → 选择钉钉目标 → 迁移”。
- 必须保留 Notion 导出包输入，作为长页面、DOM 变化和批量迁移的可靠回退。
- 浏览器界面、迁移核心和钉钉写入适配器必须解耦，以便未来增加 Chrome、CLI、桌面端或 Codex Skill，而不重写核心迁移逻辑。

## 架构边界

```text
Edge MV3 扩展
    │ 版本化 Native Messaging JSON
    ▼
Windows 本地助手
    ├─ Notion 页面/导出包适配器
    ├─ 中立文档模型（Document IR）
    ├─ 资源缓存与验证
    ├─ DOCX/富文本转换
    └─ 钉钉 DWS 适配器
```

- Edge 扩展负责当前页面入口、目标选择、进度和结果展示。
- 本地助手负责文件系统、图片、转换、任务状态和外部 CLI 调用。
- 不使用 localhost HTTP 服务替代 Native Messaging。
- 敏感凭据不得进入扩展包、Git、日志或测试夹具。
- Native Messaging 的 stdout 只能输出带长度前缀的协议消息；诊断日志只能写 stderr。

## 仓库结构

- `apps/edge-extension/`：Edge MV3 扩展源码和静态资源。
- `apps/native-host/`：Go 本地助手、协议处理和测试。
- `protocol/`：跨语言 Native Messaging JSON Schema。
- `scripts/`：Windows 构建、安装和注册脚本。
- `tests/`：跨组件自动化测试。
- `docs/`：面向开发者的架构与操作说明。
- `README.md`：只面向仓库访问者，放项目介绍、安装、使用和公开限制；不要放详细内部开发计划。
- `AGENTS.md`：Codex 工作约定、阶段计划、验收标准和当前进展。

## 语言约定

- 仓库文档、开发计划、代码注释、用户界面文案、错误提示和提交说明尽量使用中文。
- Edge、Notion、DingTalk、DWS、Native Messaging、Manifest V3、Document IR、DOCX、JSON、SHA-256 等产品名或专用名词保留官方写法。
- 命令、路径、协议字段、API 名称和代码标识符遵循对应工具或编程语言惯例，不强行翻译为中文。
- 面向用户的说明先给中文结论；确有必要时再补充英文原文或官方术语。

## 工程规则

1. 主开发环境是 Windows 原生环境，不把 WSL2 引入 Edge 与 Native Host 的运行链路。
2. Edge 扩展使用 Manifest V3，并保持最小权限；增加权限时必须说明用户价值和安全影响。
3. 跨进程协议必须版本化。修改信封时同步更新 TypeScript、Go、JSON Schema 和测试。
4. Notion 内容先转换为中立文档模型，禁止把 Notion DOM 结构直接耦合到 DWS 调用。
5. 图片进入转换流程前必须落盘，并记录来源、MIME、大小和 SHA-256；图片缺失时不得静默成功。
6. 钉钉写入使用文档导入或正文媒体能力，禁止误用钉盘上传后报告为富文本文档。
7. 所有迁移任务需要稳定任务 ID、状态记录和幂等策略。重试不得默认创建重复文档。
8. 优先使用标准库和已有依赖。新增生产依赖前检查维护状态、许可证、体积和必要性。
9. 不提交 Token、Cookie、AppKey、AppSecret、用户文档、真实企业 ID 或包含隐私的日志。
10. 不为通过测试而降低验收条件；无法验证的能力保持未完成状态并明确记录原因。

## 必需验证

按变更范围执行最小充分验证：

- 扩展代码或协议 TypeScript：`npm run check:extension`
- Go 本地助手：`npm run check:native`
- 跨组件或发布相关变更：`npm run check:all`
- PowerShell 脚本：至少做语法检查；涉及安装或注册时在受控用户级环境实测。
- Edge 界面或 Native Messaging：在 Edge 开发者模式加载 `dist/edge-extension` 做人工冒烟测试。
- Notion 解析：使用脱敏固定夹具验证块顺序、文本、图片数量和缺失资源错误。
- 钉钉写入：回读生成文档，核对文档类型、关键正文和媒体数量后才能报告成功。

每个阶段完成后，必须把实际验收命令和结果更新到“当前进展”。

## 分阶段开发计划

### 阶段 0 — 仓库基础

状态：已完成

范围：

- 建立 Edge MV3、Go Native Host、协议、脚本、测试和 CI 目录。
- 固定 Windows 原生开发路线。
- 建立扩展到 Native Host 的 `health.check` 协议。

验收：

- [x] `npm install` 成功，npm audit 为 0 个已知漏洞。
- [x] `npm run check:extension` 通过。
- [x] 扩展构建产物包含 manifest、background、popup 和 protocol。
- [x] TypeScript 协议测试通过。
- [x] PowerShell 与 JSON 文件完成静态语法检查。

### 阶段 1 — Native Messaging 真实链路

状态：进行中

范围：

- 安装 Go，编译并测试 Windows Native Host。
- 在 Edge 加载开发扩展，注册用户级 Native Messaging Host。
- 让弹窗真实显示 Native Host 版本和平台。

验收：

- [ ] `npm run check:native` 通过。
- [ ] `npm run build:native` 生成可运行的 Windows EXE。
- [ ] `npm run check:all` 通过。
- [ ] Edge 弹窗显示 `0.1.0` 和 `windows/amd64`。
- [ ] 关闭并重新启动 Edge 后健康检查仍成功。
- [ ] 未注册本地助手时，扩展显示可理解且可恢复的错误。

### 阶段 2 — 中立文档模型与转换核心

状态：待开始

范围：

- 定义页面、段落、标题、列表、引用、代码、表格、图片、附件和链接的中立模型。
- 建立本地资源仓库（Asset Store）、内容哈希、去重和任务工作目录。
- 使用脱敏夹具打通中立文档模型到自包含 DOCX 的转换。

验收：

- [ ] 固定夹具可稳定生成 DOCX。
- [ ] 标题、段落、嵌套列表、代码块、表格和链接顺序正确。
- [ ] 输出 DOCX 中的图片全部内嵌，不包含 Notion 临时 URL。
- [ ] 重复图片按哈希去重，缺失图片返回明确错误。
- [ ] 相同输入重复转换得到等价结果。

### 阶段 3 — Notion 导出包可靠适配器

状态：待开始

范围：

- 支持 Notion HTML/Markdown 导出 ZIP。
- 解析本地图片、子页面和常见 Notion 特殊块。
- 将不支持的结构显式降级并形成迁移报告。

验收：

- [ ] 代表性导出包可完整转换为中立文档模型和 DOCX。
- [ ] 源图片数、成功解析数和输出图片数可核对。
- [ ] 中文、空格、URL 编码文件名和嵌套目录可正确处理。
- [ ] Callout、Toggle、多栏和数据库的降级结果符合既定映射。
- [ ] 损坏或缺失资源不会被静默忽略。

### 阶段 4 — 钉钉富文档适配器

状态：待开始

范围：

- 检测 DWS 安装与登录状态。
- 选择钉钉组织、知识库和目标文件夹。
- 使用 DWS 文档导入能力生成在线富文本文档并回读验证。
- 建立失败恢复和幂等映射。

验收：

- [ ] 代表性 DOCX 被转换为钉钉原生可编辑文档，而非钉盘附件。
- [ ] 标题、正文、表格、代码块和内联图片在钉钉中可见。
- [ ] 回读文档能验证关键正文和媒体数量。
- [ ] Notion 图片 URL 过期后，钉钉图片仍可正常显示。
- [ ] 相同任务重试不会默认创建重复文档。

### 阶段 5 — Edge 当前 Notion 页面适配器

状态：待开始

范围：

- 识别当前 Notion 页面和页面 ID。
- 采集已登录页面中的块、图片和元数据。
- 处理长页面延迟渲染，并在无法保证完整性时引导使用导出包。

验收：

- [ ] 普通、长篇和多图片三类页面均通过固定人工验收。
- [ ] 捕获结果保持可见块顺序和层级。
- [ ] 图片在签名 URL 有效期内完成本地化。
- [ ] 未完整加载、无权限或页面类型不支持时明确阻止迁移。
- [ ] Notion DOM 选择器变化有集中适配点和回归夹具。

### 阶段 6 — 一键迁移体验

状态：待开始

范围：

- 完成目标位置选择、预检、迁移进度、取消、重试和结果链接。
- 将当前页模式与导出包模式统一到同一个任务模型。
- 提供清晰的依赖安装和授权引导。

验收：

- [ ] 新用户完成一次设置后，可从 Notion 页面一键发起迁移。
- [ ] 迁移过程中能看到当前阶段和可操作错误。
- [ ] 成功后可直接打开钉钉文档。
- [ ] 取消和失败不会留下被报告为成功的半成品。
- [ ] 24 小时后重新打开目标文档，正文图片仍正常显示。

### 阶段 7 — 打包与发布

状态：待开始

范围：

- 提供用户级 Windows 安装、升级和卸载流程。
- 准备 Edge Add-ons 包、权限说明、隐私说明和 GitHub Release。
- 建立版本兼容、回滚和发布检查。

验收：

- [ ] 在干净的 Windows 用户环境完成安装、迁移和卸载。
- [ ] 卸载只删除本项目拥有的注册表项和文件。
- [ ] 扩展与 Native Host 版本不兼容时给出升级指引。
- [ ] Release 包含校验和、安装说明和已知限制。
- [ ] CI 对扩展、本地助手和发布产物执行完整检查。

## 当前进展

最后更新：2026-08-24

当前阶段：阶段 1 — Native Messaging 真实链路

已完成：

- GitHub 空仓库已克隆并迁移到 `D:\Work\gadgets\Notion2DingDing`。
- Edge MV3 扩展、Go Native Host 和 Native Messaging v1 协议骨架已创建。
- Windows 构建与用户级 Native Host 注册脚本已创建。
- GitHub Actions Windows CI 已创建。
- Node.js 依赖已安装，npm audit 报告 0 个漏洞。
- `npm run check:extension` 已通过：TypeScript 类型检查成功，2 项协议测试通过。
- 扩展已构建到 `dist/edge-extension`。
- README 已调整为面向仓库使用者；详细计划由本文件维护。
- 仓库文档和开发记录已统一采用“中文优先，专用名词保留官方写法”的语言约定。

尚未验证：

- 当前开发机尚未安装 Go，Native Host 没有完成本机构建与 Go 测试。
- 当前开发机尚未安装 DWS，钉钉登录和富文档导入未验证。
- Edge 扩展尚未在 `edge://extensions` 加载。
- Native Messaging Host 尚未写入注册表，真实健康检查尚未打通。
- Notion 内容提取和钉钉写入尚未实现。
- 当前初始化文件尚未创建第一次 Git commit，也未推送到远端。

下一步：

1. 安装 Go 1.22+，运行 `npm run check:native` 和 `npm run build:native`。
2. 运行 `npm run check:all`。
3. 在 Edge 加载 `dist/edge-extension`，取得扩展 ID。
4. 运行 `scripts/install-native-host.ps1` 注册本地助手。
5. 验证弹窗健康检查，并把实际结果更新到本文件。

## 进度维护规则

- 开始任务前先读取本文件的“当前进展”、当前阶段和验收条件。
- 只处理当前阶段，除非用户明确调整优先级或前置依赖要求提前实现下一阶段内容。
- 一个阶段只有在所有验收项实际通过后才能标记为“已完成”。
- 每次完成实质开发后更新“最后更新”“已完成”“尚未验证”和“下一步”。
- README 只同步用户可见能力、安装方式和公开限制，不复制本文件的详细内部计划。
- 如果设计决策改变产品契约、阶段顺序或验收标准，先更新本文件，再实现代码。
