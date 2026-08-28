# Microsoft Edge Add-ons 提交文案草案

## 单一用途

把用户主动选择的 Notion 官方 HTML 导出 ZIP，通过安装在同一台 Windows 电脑上的本地迁移核心，转换为可编辑、可验证的钉钉在线文档。

## 扩展名称

Notion2DingDing

## 简短说明

将 Notion 官方 HTML 导出包迁移为可编辑的钉钉在线文档。

## 完整说明

Notion2DingDing 帮助 Windows 用户把 Notion 页面迁移为可继续编辑的钉钉在线文档。扩展识别当前 Notion 页面并提供迁移入口；用户选择 Notion 官方 HTML 导出 ZIP 后，扩展先显示包内标题、导出时间和页面数量，只有再次点击“开始转换”才执行迁移。标题可修改，子页面既可合并到同一文档，也可选择递归文档树模式。迁移过程展示预检、转换、写入、回读和清理进度，成功后可直接打开钉钉文档；遇到已有导出记录时会显示可核对的钉钉链接，并允许用户明确选择再次导出。

正文转换、图片处理和钉钉写入均由用户安装在本机的 Windows 助手完成，本项目不运营用于接收用户文档的中转服务器。首次使用需要按扩展提示安装一次本地助手，并完成钉钉登录和保存位置选择；此后日常操作只需使用 Edge 扩展。迁移结果使用钉钉原生文档和钉钉托管图片。Notion2DingDing 是独立迁移工具，与 Notion、钉钉和 Microsoft Edge 官方无隶属、联合或背书关系。

## 权限说明

- `activeTab`：仅在用户打开扩展时读取当前活动标签页，用于判断当前页是否为 Notion 页面。
- `scripting`：向当前 Notion 标签页执行一次只读脚本，读取页面标题和可见块/图片数量，提供完整性提示；不会把 DOM 作为迁移正文。
- `nativeMessaging`：把用户主动选择的 HTML ZIP 传给本机安装的 Notion2DingDing 助手，并接收健康状态、迁移进度和结果。
- `storage`：仅使用 `chrome.storage.session` 保存当前任务 ID和稳定 Notion 页面 ID，以便关闭再打开弹窗后恢复同一页面的任务；不保存 ZIP、正文、图片、钉钉凭据或目标内部 ID。

## 远程代码

不使用远程托管 JavaScript、WebAssembly 或动态下载执行代码。GitHub Release 链接只用于由用户主动下载 Windows 本地助手。

## 数据披露摘要

扩展会访问当前标签页地址、页面标题、可见块/图片数量，以及用户主动选择的 Notion HTML ZIP。ZIP 通过 Native Messaging 交给本机助手，之后由用户已授权的钉钉官方 dws 写入钉钉。项目不含广告、分析、遥测或跨站跟踪，不把文档发送到项目自有服务器。详细说明见仓库根目录 `PRIVACY.md`。

## 审核测试备注

该扩展依赖 Windows Native Messaging Host。审核人员可先安装 GitHub Release 中的 `Notion2DingDing-Setup.exe`，完全重启 Edge 后打开扩展。v0.1.0 安装器暂未进行 Authenticode 签名；请先用同一 Release 的 `checksums.sha256` 核对文件，再在 SmartScreen 中选择“更多信息 → 仍要运行”。若没有钉钉授权，仍可验证本地助手连接、版本兼容检查、Notion 页面识别和安装/升级引导；真实迁移需要审核账号能够登录钉钉并选择有写入权限的目标文件夹。

最终 Windows 安装包已经把 Microsoft Edge Add-ons 分配的 CRX ID `pgjapgiiikkdkmcjmahnggdbfglfihbp` 写入 Native Host `allowed_origins`，并保留固定开发 ID供本地调试。
