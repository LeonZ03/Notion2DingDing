# 内容映射与降级规则

本文件记录 Notion `Markdown & CSV` 导出进入钉钉在线文字文档时的稳定映射。工具不会猜测导出包已经丢失的布局信息；无法保真的结构必须出现在迁移报告的 `local.mappings` 和 `local.warnings` 中。

Notion 官方说明：非数据库页面导出为 Markdown，完整数据库导出为 CSV，子页面导出为独立文件，Callout 因没有 Markdown 等价物而导出为 HTML。Pandoc 支持把多个输入合并后转换，因此当前方案继续复用 Pandoc，不引入新的生产解析依赖。

- [Notion：Export your content](https://www.notion.com/help/export-your-content)
- [Pandoc User’s Guide](https://pandoc.org/MANUAL.html)

## 页面与子页面

- 自动扫描 Markdown 本地链接，推断唯一根页面。
- 按链接顺序递归收集可达子页面，循环链接和重复链接只处理一次。
- 子页面追加到同一篇钉钉文档，标题层级下移一级。
- 原子页面树、权限和独立页面 URL 不迁移。
- 多个独立根页面无法唯一推断时，要求用户显式传入 `--entry`。
- 链接指向的 Markdown 缺失时立即失败，不调用钉钉写接口。

## 图片

- 拒绝 Notion 或其他 HTTP(S) 外部图片 URL、data URI、绝对路径和越界路径。
- 对每个本地文件记录相对路径、MIME、字节数、引用次数和 SHA-256。
- 相同 SHA-256 只复制一份准备资源；Markdown 中的每个图片位置仍保留。
- DOCX 验证同时检查媒体文件数、图片关系数、图片实际出现次数、外部图片关系和 Notion 临时 URL。
- 钉钉回读图片数量不得少于源 Markdown 图片引用数。

## 特殊结构

| 源结构 | 输出 | 报告状态 |
| --- | --- | --- |
| Callout HTML | 带 `Callout` 标识的引用块 | `mapped` |
| Toggle HTML | 标题和正文展开为引用文本 | `degraded` |
| 多栏 | 按 Notion 导出顺序线性排列 | `source_flattened` 或 `degraded` |
| 数据库 CSV | 正文显示 CSV 降级说明，报告 CSV 路径、大小和 SHA-256 | `degraded` |
| 普通附件 | 正文显示未嵌入提示 | 显式降级 |

## 固定回归夹具

- 普通夹具：标题、正文、列表、表格、代码块、链接和两张 PNG。
- 长篇夹具：30 节、80 个以上 DOCX 段落，并检查开头、中间和末尾唯一标记。
- 多图片夹具：8 个图片引用、8 个本地文件、2 个唯一内容哈希，验证去重后仍保留 8 个输出位置。
- 子页面与特殊块夹具：两层子页面、中文与空格路径、URL 编码、Callout、Toggle、CSV 和两张图片。

运行 `npm run check:stage3` 会依次回归阶段 1、阶段 2 和以上阶段 3 夹具。
