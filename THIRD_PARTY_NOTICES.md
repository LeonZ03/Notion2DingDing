# 第三方组件与品牌说明

最后更新：2026-08-28

Notion2DingDing 的发布包和安装流程涉及以下第三方组件。各组件仍受其原始许可证约束；本文件不是许可证文本的替代品。

| 组件 | 当前验证版本 | 用途 | 分发方式 | 许可证/来源 |
| --- | --- | --- | --- | --- |
| Go | 1.22+ | 编译 Windows Native Host 和安装引导程序 | 发布包包含编译产物 | BSD-style，<https://go.dev/LICENSE> |
| Node.js | 24+ | 运行本地迁移编排 | 安装时由 winget 获取，不直接打包 | MIT，<https://github.com/nodejs/node> |
| Pandoc | 3+ | HTML/DOCX 格式转换 | 安装时由 winget 获取，不直接打包 | GPL-2.0-or-later，<https://pandoc.org> |
| DingTalk Workspace CLI（dws） | 1.0.59 | 钉钉登录、目录选择、文档导入和回读 | 安装时由 npm 获取，不直接打包 | Apache-2.0，<https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli> |
| TypeScript | 5.9.x | 构建 Edge 扩展 | 只分发编译后的扩展 JavaScript | Apache-2.0，<https://github.com/microsoft/TypeScript> |

Edge 扩展图标是根据用户提供的 Notion 与钉钉视觉参考重新生成的独立组合图形；发布包不包含用户提供的原始参考图片。Notion、DingTalk、钉钉、Microsoft Edge 及其标志和名称可能是各自权利人的商标。本项目仅用名称说明兼容和迁移方向，不暗示官方授权、联合开发或背书。

本仓库目前尚未由项目所有者指定源代码开源许可证。正式公开发布前必须由项目所有者确认项目许可证；在此之前，不应把第三方许可证理解为对本项目自有代码的授权。
