# 架构说明

## 目标

最终用户只需要在 Notion 页面点击 Edge 扩展并选择钉钉目标位置。实现上将浏览器入口与迁移核心分开，以避免浏览器沙箱、凭据存储和页面 DOM 变化影响核心可靠性。

## 组件

### Edge 扩展

- Manifest V3
- 展示页面识别、目标选择、进度和结果
- 通过 Native Messaging 调用本地助手
- 不保存 Notion 或钉钉应用密钥

### Windows 本地助手

- 单个 Windows 可执行程序
- 处理 Native Messaging 长度前缀协议
- 管理任务状态、图片缓存和中间文件
- 调用 Pandoc 与 DingTalk Workspace CLI
- 后续可提供相同协议的 CLI 调试入口

### 迁移核心

核心使用中立文档模型，输入和输出通过适配器解耦：

```text
Notion DOM ─────┐
Notion Export ──┼─> Document IR ─> Asset Store ─> DOCX ─> DingTalk DWS
Notion API ─────┘
```

第一阶段只建立协议和运行骨架；迁移功能按照“导出包适配器 → 当前页面适配器 → Notion API 适配器”的顺序增加。

## 协议

Native Messaging 使用 4 字节小端长度前缀和 UTF-8 JSON。应用层信封定义在 `protocol/native-message.schema.json`。

每个请求包含：

- `protocolVersion`
- `requestId`
- `method`
- `params`

每个响应保留相同的 `requestId`，并返回 `ok/result` 或 `ok/error`。

协议按版本演进。新增字段优先保持向后兼容；破坏性修改才提升 `protocolVersion`。

## 安全边界

- 扩展只申请当前阶段需要的最小权限
- Native Messaging Host 只允许明确的 Edge 扩展 ID
- 敏感登录态由 DWS/操作系统凭据存储管理
- 不启动本地 HTTP 端口
- 所有下载图片先校验大小、类型和哈希，再进入转换流程
