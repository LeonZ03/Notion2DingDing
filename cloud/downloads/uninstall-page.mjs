export const uninstallPage = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>卸载本地助手 · Notion2DingDing</title>
<style>
:root{font:16px/1.65 "Segoe UI","Microsoft YaHei",sans-serif;color:#242424;background:#f7f8fa}*{box-sizing:border-box}body{margin:0}main{max-width:760px;margin:48px auto;padding:32px;background:white;border:1px solid #e4e7ec;border-radius:16px}h1{font-size:28px;line-height:1.3;margin:8px 0 16px}h2{font-size:20px;margin:28px 0 8px}p{margin:10px 0}.brand{font-size:14px;color:#1765b5;font-weight:700}a{color:#1765b5;text-underline-offset:3px}a:focus-visible{outline:3px solid #2383e2;outline-offset:4px}.button{display:inline-block;padding:10px 20px;background:#1765b5;color:white;text-decoration:none;border-radius:8px;font-weight:600;min-height:46px}.note{padding:14px 18px;border-left:3px solid #2383e2;background:#f3f7fc}.muted{color:#555}pre{white-space:pre-wrap;overflow-wrap:anywhere;padding:16px;background:#f4f5f7;border-radius:8px;font:14px/1.6 Consolas,monospace}li{margin:8px 0}footer{margin-top:28px;padding-top:16px;border-top:1px solid #e4e7ec;font-size:14px;color:#555}@media(max-width:600px){main{margin:16px 12px;padding:24px 20px}h1{font-size:25px}}
</style></head><body><main>
<p class="brand">Notion2DingDing</p><h1>还需要卸载 Windows 本地助手吗？</h1>
<p>如果你刚刚移除了 Edge 扩展，本地助手可能仍保留在电脑中。浏览器移除扩展时不会自动卸载 Windows 程序，本页也不会检测或操作你的电脑。</p>
<h2>从 Windows 卸载</h2>
<ol><li>等待迁移结束，完全关闭 Edge 和本地助手窗口。</li><li>打开 <strong>设置 → 应用 → 已安装的应用</strong>，找到 <strong>Notion2DingDing 本地助手</strong>，选择“卸载”。Windows 10 对应“应用和功能”。</li><li>也可以在开始菜单搜索 <strong>卸载 Notion2DingDing</strong>。</li><li>在卸载确认窗口中，按需选择是否清除钉钉 DWS 登录状态，再确认卸载。</li></ol>
<p><a class="button" href="ms-settings:appsfeatures">打开 Windows 应用设置</a></p>
<h2>旧版本找不到卸载入口？</h2>
<p>重新下载最新安装器，在其所在文件夹打开 PowerShell，运行下方命令即可。无需先重新安装。</p>
<p><a href="/downloads/Notion2DingDing-Setup.exe">下载 Windows 安装器</a> · <a href="/downloads/checksums.sha256">核对 SHA-256</a></p>
<pre>.\\Notion2DingDing-Setup.exe -Action Uninstall  # 卸载本地助手及项目专属依赖</pre>
<div class="note"><strong>哪些数据会保留？</strong><p>用户提供的 Notion 导出包、已经生成的钉钉文档，以及其他工具安装的共享 Node.js、Pandoc、dws 都会保留。仅本项目管理的专属依赖会被清理。</p><p>默认保留钉钉登录状态。勾选清除登录状态将影响本机其他使用 DWS 的工具，之后需要重新登录。</p></div>
<p class="muted">命令行如需同时清除全部本机 DWS 登录状态，明确添加 <code>-RemoveDingtalkLogin</code>。此操作不会删除钉钉在线文档。</p>
<footer>本页不包含表单、遥测或跟踪，不收集你的文档或钉钉账号。<p><a href="/">返回项目下载站</a></p></footer>
</main></body></html>`;

export function uninstallResponse(method) {
  return new Response(method === 'HEAD' ? null : uninstallPage, { headers: {
    'content-type':'text/html; charset=utf-8', 'cache-control':'no-store',
    'x-content-type-options':'nosniff', 'referrer-policy':'no-referrer',
    'content-security-policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
  } });
}
