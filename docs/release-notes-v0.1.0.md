# Notion2DingDing v0.1.0

首个公开预览版本。推荐从 Microsoft Edge Add-ons 安装扩展，再按扩展提示安装一次 Windows 本地助手。

## 主要能力

- 读取 Notion 官方 HTML 导出 ZIP，选择后先显示包内标题、导出时间和页面数量，不会立即转换。
- 把正文、图片、表格、代码块、待办、多栏和子页面迁移为可编辑的钉钉在线文档。
- 子页面默认在同一文档内展开，也可选择递归创建钉钉文档树。
- 显示钉钉登录、保存位置、迁移阶段、可取消状态和最终文档链接。
- 若发现历史导出记录，提供原钉钉文档链接，同时允许用户明确选择再次导出。
- 成功、失败和写入状态未知时均清理工具生成的内容型临时文件。

## 首次安装

1. 从 Edge Add-ons 安装 Notion2DingDing。
2. 打开扩展并下载 `Notion2DingDing-Setup.exe`。
3. 核对本发布页 `checksums.sha256`。
4. 运行安装器，完成后完全关闭并重新打开 Edge。
5. 在扩展中完成钉钉登录和保存位置选择。

## 已知限制

- Windows 本地助手 v0.1.0 暂未进行 Authenticode 代码签名，SmartScreen 可能显示“Windows 已保护你的电脑”。确认文件来自本项目官方 Release 且 SHA-256 匹配后，可选择“更多信息 → 仍要运行”。
- 迁移输入必须是 Notion 官方 HTML 导出 ZIP；不支持 Markdown & CSV 导出。
- Notion 没有提供可靠的一键官方 HTML 导出 API，因此仍需用户在 Notion 中手动导出 ZIP。
- 首次安装可能需要通过 winget/npm 安装 Node.js、Pandoc 和钉钉官方 dws，耗时取决于网络。
- 本项目是独立迁移工具，与 Notion、钉钉和 Microsoft Edge 官方无隶属、联合或背书关系。

完整安装、校验、升级和卸载方法见 `安装与升级说明.md`。
