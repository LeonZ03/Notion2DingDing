# 项目下载源

入口为 `https://notion2dingding.leonz03.dpdns.org/`，独立 Worker 名称 `notion2dingding-downloads`。参考相邻 Whisper 的 Workers Static Assets 分片分发方案，每片 8 MiB；原始文件超过静态资产单文件限制时仍通过同一个下载 URL 返回完整文件，并支持单段 Range。浏览器和安装器均不跳转到 GitHub 或 OSS。

## 构建与部署

```powershell
npm ci                         # 安装锁定的开发依赖
npm run build:release          # 生成安装器与 Edge 商店提交 ZIP
npm run build:downloads        # 只将白名单发布文件和运行时分片放入 dist/download-site
npm run test:downloads         # 验证完整下载、HEAD、Range、损坏分片与路由限制
npm run deploy:downloads       # 重构建并部署独立下载 Worker 和自定义域名
```

Wrangler 使用操作者已有的 Cloudflare 登录。账户标识可以出现在配置中，Token 不进入源码或客户端。域名绑定由 Cloudflare Custom Domain 创建 DNS 和证书；没有数据库、持久化用户内容或 R2 资源。

`dist/mirror/` 必须预先放入以下官方原始包。构建时从安装脚本固定参数核对对应 SHA-256，缺失或不一致不得部署：

| 文件 | 来源与核验 |
| --- | --- |
| node-v24.16.0-win-x64.zip | nodejs.org 同版本 SHASUMS256.txt |
| pandoc-3.11-windows-x86_64.zip | jgm/pandoc 官方 3.11 发布资产 |
| dws-windows-amd64-1.0.59.zip | npm dingtalk-workspace-cli@1.0.59 内置 Windows 资产及 checksums.txt |

站点还提供第三方说明、隐私说明、安装说明、Node 官方校验和和 Pandoc 对应源码归档。`downloads/checksums.sha256` 包含所有公开下载文件；`release-manifest.json` 记录全包长度、SHA-256 和分片。GitHub 可以作为维护者取包和源码存档位置，用户安装只访问本项目下载站。

## 验收

部署后读取 `/api/health`，逐一下载全部三项运行时和安装器，核对响应总长度与 SHA-256；不能用 HEAD 或构建成功代替完整文件回读。Edge 商店更新需要将 `dist/release/v<版本>/Notion2DingDing-Edge-v<版本>.zip` 提交审核，线上旧版不会因为源码变化自动改变下载按钮。

2026-10-28：下载站 0.1.1 的 12 个公开文件已完整回读并通过大小与 SHA-256 校验，跨分片 Range 验证通过。Edge 0.1.1 已提交 Microsoft 审核，Partner Center 显示“正在审阅”；0.1.0 继续在线。新版下载按钮需等商店审核通过后才随扩展更新生效。

Cloudflare 全球网络并非中国大陆专用 CDN，国内可达性和速度仍以用户网络实测为准。免费计划的额度和限制以 Cloudflare 控制台和官方文档为准；本项目不升级付费计划。
