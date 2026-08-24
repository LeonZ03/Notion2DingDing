# 本地迁移契约

本文档描述阶段 2 的本地可用链路。当前 MVP 运行在 Windows，输入为 Notion 的 `Markdown & CSV` 导出 ZIP 或解压目录，输出为钉钉在线文字文档。

## 一条命令迁移

```powershell
npm run migrate -- --input "D:\Downloads\Notion-Export.zip" --folder "目标文件夹 nodeId"
```

知识库目标改用 `--workspace "workspaceId"`。两种目标必须且只能选择一个。可用 `--name` 指定标题，用 `--entry` 处理包含多个 Markdown 的导出包。

命令依次完成登录预检、图片资源预检、DOCX 生成、钉钉导入和真实文档 URL 回读。进度写入标准错误，最终结果以 JSON 输出；只有回读验证通过才会返回 `success: true` 和文档链接。

## 内容映射

| Notion 导出内容 | 钉钉文档映射 |
| --- | --- |
| 一级、二级标题 | 可编辑标题 |
| 段落、粗体、斜体 | 可编辑富文本 |
| 有序、无序和嵌套列表 | 对应列表；极深层级以钉钉最终支持为准 |
| Markdown 表格 | 可编辑表格 |
| 代码块 | 保留代码文本；语法高亮与语言标签不作为 MVP 保真承诺 |
| Markdown 链接 | 可点击链接 |
| 本地图片 | 先嵌入 DOCX，再由钉钉导入为其托管资源；不保留 Notion 临时 URL |

远程图片 URL 不属于当前可靠链路，预检会明确拒绝。请使用 Notion 导出包中随文档下载的本地图片。

## 可靠性约束

- 输入文件、图片和 DOCX 都会计算 SHA-256；图片缺失、越界或 ZIP 损坏时不会调用钉钉写接口。
- 同一输入、标题、目标和 profile 会生成稳定的本地任务 ID。已有成功记录时默认复用结果，避免重复创建文档；确需新建时使用 `--force`。
- 写入结果未知时记录 `taskId`（若服务端提供），状态为 `unknown`，并禁止自动重试，避免重复文档。
- 使用 `--profile` 时，登录检查、导入和回读始终使用同一个 profile。
- 运行记录和中间 DOCX 位于 `artifacts/migrations/`，该目录不进入 Git。

## 主要错误码

| 错误码 | 含义与处理 |
| --- | --- |
| `DWS_NOT_AUTHENTICATED` | 未登录或 Token 失效；先运行 `dws auth login` |
| `CONVERSION_FAILED` | ZIP、Markdown 或图片资源有问题；根据错误修复输入后重试 |
| `IMPORT_PERMISSION_DENIED` | 当前账号对目标目录或知识库无写权限 |
| `IMPORT_COMMIT_UNKNOWN` | 写入结果未知；先按任务记录人工确认，不能直接重试 |
| `READBACK_FAILED` / `READBACK_MISMATCH` | 服务端可能已创建文档，但验证未通过；按返回链接或任务 ID 确认 |

## 图片持久性验收

迁移成功时会检查回读内容中的图片数量。正式阶段验收还需在文档创建至少 24 小时后再次打开或回读，确认图片仍可见；该检查用于证明图片已经进入钉钉托管资源，而不是继续依赖 Notion 临时链接。
