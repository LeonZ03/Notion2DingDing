# 阶段 1 工具选型记录

最后核查：2026-08-24

## 结论

阶段 1 采用“官方导出 + 成熟开源转换器 + 钉钉官方开源 CLI”的最短链路：

```text
Notion 官方 Markdown & CSV 导出
            │
            ▼
Pandoc 生成自包含 DOCX
            │
            ▼
DingTalk Workspace CLI（dws）导入在线富文档
```

项目只实现输入检查、流程编排、结果验证和错误处理，不自行实现 Markdown 解析器、DOCX 生成器或钉钉文档导入协议。

## 采用工具

### Notion 官方导出

- 用途：得到 Markdown/CSV、子页面和本地图片等源内容。
- 来源：[Notion 官方导出说明](https://www.notion.com/help/export-your-content)
- 版本：Notion 在线服务，无独立本地版本；以实际导出 ZIP 格式为兼容边界。
- 许可证：Notion 产品功能，不随本项目再分发。
- Windows 支持：支持浏览器或桌面端导出；官方提示嵌套页面可能触发 Windows 260 字符路径限制。
- 维护状态：Notion 官方持续维护。
- 已知限制：Callout 等没有 Markdown 等价表示的内容可能导出为 HTML；数据库会导出为 CSV；导出者无权限的页面不会包含在结果中。
- 退出方案：后续增加 Notion HTML 导出适配器；Edge 当前页采集仅作为补充入口，不替代导出包基线。

### Pandoc

- 用途：把 Markdown 与本地资源转换为 DOCX，并由 DOCX 容器内嵌图片。
- 来源：[Pandoc 官方仓库](https://github.com/jgm/pandoc)与[官方 Windows 安装说明](https://pandoc.org/installing.html)
- 本机验证版本：`3.8.2.1`。
- 版本策略：阶段 1 固定记录实际验证版本；升级时重新运行 `npm run check:stage1`。
- 许可证：GPL-2.0-or-later。
- Windows 支持：官方提供 MSI 和 ZIP 二进制包。
- 维护状态：活跃维护，有持续 Release、文档和测试。
- 集成方式：仅作为独立进程调用，不复制或修改其源码。若未来随安装包分发 Pandoc，必须一并满足其许可证要求。
- 已知限制：Notion 特殊块与复杂布局可能降级；DOCX 的具体样式不等于 Notion 原样排版。
- 退出方案：保留转换适配器边界；真实夹具无法通过时，可替换为其他成熟转换器或只补充最小 Pandoc Lua Filter。

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

## 暂不采用或暂缓自研

- 自研 Markdown/HTML 解析器：Pandoc 先覆盖常见结构，只有真实夹具失败时才补缺口。
- 自研 DOCX 生成器：Pandoc 已提供成熟实现，阶段 1 没有重复开发的价值。
- 自研钉钉上传与转换协议：`dws doc +import` 已封装上传、转换和任务轮询。
- Edge DOM 抓取：本地导出链路通过阶段 1 至阶段 3 验收后再开始。
- Native Messaging：只作为未来 Edge 的传输层，不阻塞当前本地工具。

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
