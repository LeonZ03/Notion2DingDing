# 阶段 1 工具选型记录

最后核查：2026-08-24

## 结论

阶段 1 采用“官方导出 + 成熟开源转换器 + 钉钉官方开源 CLI”的最短链路：

```text
Notion 官方 HTML 导出
            │
            ▼
Pandoc 生成自包含 DOCX
            │
            ▼
DingTalk Workspace CLI（dws）导入在线富文档
```

项目只实现输入检查、流程编排、结果验证和错误处理。HTML 与 DOCX 主转换继续交给 Pandoc；项目仅用小型 Lua Filter 和 OOXML 整理脚本补齐 Notion 多栏布局，不自研完整 HTML 解析器、DOCX 生成器或钉钉导入协议。

## 采用工具

### Notion 官方导出

- 用途：得到保留 `column-list`、`column`、列宽、表格、子页面链接和本地图片的 HTML 源内容。
- 来源：[Notion 官方导出说明](https://www.notion.com/help/export-your-content)
- 版本：Notion 在线服务，无独立本地版本；以实际导出 ZIP 格式为兼容边界。
- 许可证：Notion 产品功能，不随本项目再分发。
- Windows 支持：支持浏览器或桌面端导出；官方提示嵌套页面可能触发 Windows 260 字符路径限制。
- 维护状态：Notion 官方持续维护。
- 已知限制：部分数据库仍可能以 CSV 或静态表格表达；导出者无权限的页面不会包含在结果中。
- 退出方案：长期保留官方 HTML 导出包作为可靠基线；Edge 当前页采集仅作为补充入口。

### Pandoc

- 用途：把 HTML 与本地资源转换为 DOCX，并由 DOCX 容器内嵌图片；Lua Filter 将 Notion 多栏映射为一行布局表。
- 来源：[Pandoc 官方仓库](https://github.com/jgm/pandoc)与[官方 Windows 安装说明](https://pandoc.org/installing.html)
- 本机验证版本：`3.8.2.1`。
- 版本策略：阶段 1 固定记录实际验证版本；升级时重新运行 `npm run check:stage1`。
- 许可证：GPL-2.0-or-later。
- Windows 支持：官方提供 MSI 和 ZIP 二进制包。
- 维护状态：活跃维护，有持续 Release、文档和测试。
- 集成方式：仅作为独立进程调用，不复制或修改其源码。若未来随安装包分发 Pandoc，必须一并满足其许可证要求。
- 已知限制：Pandoc 不会自动把 Notion `column-list` 变成 Word 多栏，也不会自动限制列内图片宽度，因此项目增加了可替换的最小 Filter 与 OOXML 后处理；DOCX 具体样式仍不等于像素级还原 Notion。
- 退出方案：转换适配器、Lua Filter 和钉钉写入互相解耦；真实夹具失败时可单独替换 Filter 或转换器。

### Windows System.Drawing

- 用途：仅当图片总体积可能超过钉钉 DOCX 导入上限时，在工具临时目录中把较大的 PNG 以 JPEG 质量 92 重新编码；源导出包不修改。
- 来源与版本：Windows PowerShell 5.1 随 .NET Framework 提供的系统组件，不新增下载项或生产依赖。
- Windows 支持：项目主运行环境原生提供；转换后仍由 Pandoc 和 DOCX 审计核对媒体数量、关系与外部 URL。
- 已知限制：这是有损优化，透明像素会合成到白色背景；仅在总体积超过 19 MiB 时启用，较小文档保持原图。
- 退出方案：优化位于转换适配层，可替换为 ImageMagick 等成熟工具；最终 DOCX 仍超过 20 MiB 时在调用 dws 前明确失败。

### Go

- 用途：构建 Windows Native Messaging Host；只负责版本化协议、输入边界、安全暂存和调用已安装的阶段 4 CLI。
- 来源：[Go 官方下载](https://go.dev/dl/)。
- 本机验证版本：`1.26.7 windows/amd64`；项目最低版本为 `1.22`。
- 许可证：BSD-3-Clause。
- Windows 支持：官方提供 amd64 ZIP/MSI；阶段 5 使用当前用户级目录 `%LOCALAPPDATA%\Programs\Go`，不把 Go 运行时打进迁移核心。
- 安全边界：Host stdout 只写 Native Messaging 帧；不提供 localhost 服务，不解析或实现钉钉写入协议。
- 退出方案：Native Host 是薄传输层；CLI 仍可脱离 Edge 独立运行。

### DingTalk Workspace CLI（dws）

- 用途：登录钉钉、选择目标位置、将本地 DOCX 转换为钉钉在线可编辑文档并回读验证。
- 来源：[钉钉官方开源仓库](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli)
- 固定版本：`1.0.59`，npm 包名 `dingtalk-workspace-cli`。
- 安装命令：`npm install -g dingtalk-workspace-cli@1.0.59`。
- 许可证：Apache-2.0。
- Windows 支持：官方提供 PowerShell、npm 和预编译二进制安装方式；凭据在 Windows 下使用当前用户的 DPAPI 保护。
- 维护状态：活跃维护；`1.0.59` 于 2026-08-20 发布，Release 带签名提交，升级流程校验 SHA-256。
- 采用命令：`dws doc +import --file <相对路径> --folder <目标文件夹 nodeId> --format json`；成功后检查 `success`、`taskId` 与 `documentUrl`，再用真实 `nodeId` 回读正文。
- 安全边界：只使用 OAuth/官方凭据存储，不读取浏览器 Cookie，不把 Token 或 AppSecret 写入仓库和日志。
- 已知限制：访问企业数据需要管理员授权；项目仍处于官方所称的共创阶段；不同组织和目标文件夹受真实权限控制。`1.0.59` 的 `+import --help` 表示可以省略目标位置，但本次真实 API 返回必须提供 `folder` 或 `workspace`，因此项目当前把目标位置视为必填。
- 退出方案：适配器只依赖公开 CLI JSON 契约。若版本回归，固定到最后通过验收的版本；若官方接口策略变化，重新评估官方 OpenAPI，不采用来源不明的第三方协议。

### Edge 扩展品牌图标

- 用途：在 Edge 工具栏和扩展弹窗中表达“Notion → DingTalk”迁移关系。
- 输入来源：用户于 2026-08-27 提供的 Notion 黑色品牌参考图和钉钉蓝色品牌参考图；仓库不保存用户临时目录中的原始附件。
- 生成方式：使用 OpenAI 内置图像生成工具重新组合为 `assets/extension-icon/icon-master-v2.png`，再由 `scripts/generate-extension-icons.ps1` 以 System.Drawing 高质量缩放为 `16/32/48/128px`；主图不进入扩展安装包。
- 权利说明：Notion、DingTalk 名称、商标与品牌图形权利归各自权利人；本项目只用于描述兼容迁移关系，不声称官方隶属、联合发布或背书。
- 发布边界：当前可用于用户本地开发模式验收；进入 Edge Add-ons 公开发布前，阶段 7 必须再次核对两家当时有效的品牌使用规范，必要时替换为不含官方商标的抽象图形。
- 退出方案：Manifest 只引用四个尺寸化 PNG；可整体替换主图并重新运行生成脚本，不影响迁移功能或 Native Messaging 协议。

## 暂不采用或暂缓自研

- 自研完整 HTML 解析器：Pandoc 已保留 Notion Div/Table/Image AST；项目只补多栏到布局表的缺口。
- 自研 DOCX 生成器：Pandoc 已提供成熟实现，阶段 1 没有重复开发的价值。
- 自研钉钉上传与转换协议：`dws doc +import` 已封装上传、转换和任务轮询。
- Edge DOM 全量抓取：阶段 5 只识别当前页和可见规模；Notion 长页面与懒加载内容无法证明完整，因此仍使用官方 HTML 导出 ZIP。
- 自研本地 HTTP 服务：Native Messaging 已满足 Edge 与本地核心通信，不引入 localhost 服务和额外端口攻击面。

## 可重复验证

```powershell
npm run check:stage1
```

该命令会分别用目录和 ZIP 输入生成 DOCX，并检查：

- 文档正文包含阶段 1 固定文本；
- `word/media/` 至少包含两项媒体资源；
- 图片关系全部指向 DOCX 内部资源，不使用外部图片关系；
- DOCX XML 与关系文件中不存在 Notion 临时图片域名。

钉钉真实导入需要先完成一次用户登录：

```powershell
dws auth login
dws auth status --format json
dws doc +import `
  --file artifacts/stage1/notion-stage1-directory.docx `
  --folder <TARGET_FOLDER_NODE_ID> `
  --name "Notion2DingDing 阶段 1 验证" `
  --format json
```

导入属于远端写操作。必须保留真实返回的 `taskId` 和 `documentUrl`，并打开或回读目标文档后才能将阶段 1 标记为完成。

## 2026-08-24 验收记录

- 本机版本：Windows、Pandoc `3.8.2.1`、Node.js `24.16.0`、npm `11.13.0`、dws `1.0.59`。
- dws 安装来源：npm 官方包；包元数据显示 Apache-2.0、官方仓库地址和固定完整性哈希。
- OAuth：只授权 `doc` 文档业务域，没有授予聊天、通讯录、邮箱、审批、钉盘或知识库权限。
- `npm run check:stage1`：通过。目录与 ZIP 两种输入均生成 `16963` 字节的 DOCX。
- 两个 DOCX 验证结果一致：`mediaCount=2`、`imageRelationshipCount=2`、`externalImageRelationships=0`、`notionTemporaryUrls=0`。
- 首次省略目标位置的导入被 API 拒绝；按唯一标题搜索确认没有创建文档后，指定专用目标文件夹重新导入。
- 指定目标后 `dws doc +import` 返回 `success=true`、真实 `taskId` 和在线文档 URL。
- 使用返回的真实 `nodeId` 回读成功：标题、正文、嵌套列表、表格与两张图片均存在，图片资源域名属于钉钉 `alidocs2`，不包含 Notion 地址。
- 在线文档 ID、组织、用户和凭据不写入仓库；用户可从本次执行结果直接打开测试文档。
