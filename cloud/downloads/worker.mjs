import { uninstallResponse } from './uninstall-page.mjs';
const CHUNK = 8 * 1024 * 1024;

function responseError(status, message) { return new Response(message, { status, headers: { 'content-type': 'text/plain; charset=utf-8' } }); }
function parseRange(value, size) {
  const m = /^bytes=(\d*)-(\d*)$/.exec(value ?? '');
  if (!m || (!m[1] && !m[2])) return null;
  let start, end;
  if (!m[1]) { const suffix = Number(m[2]); if (!suffix) return null; start = Math.max(0, size - suffix); end = size - 1; }
  else { start = Number(m[1]); end = m[2] ? Number(m[2]) : size - 1; }
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || end < start) return null;
  return [start, Math.min(end, size - 1)];
}
async function readManifest(env, origin) {
  const r = await env.ASSETS.fetch(new Request(origin + '/release-manifest.json'));
  if (!r.ok) throw new Error('release manifest unavailable');
  const m = await r.json();
  if (typeof m.version !== 'string' || !/^\d+\.\d+\.\d+$/.test(m.version) || !Array.isArray(m.files)) throw new Error('invalid release manifest');
  for (const f of m.files) if (typeof f.path !== 'string' || !/^\/downloads\/[\p{L}\p{N}_-]+(?:\.[\p{L}\p{N}_-]+)*$/u.test(f.path) || !Number.isSafeInteger(f.bytes) || f.bytes < 0 || !/^[a-f0-9]{64}$/.test(f.sha256) || !Array.isArray(f.chunks) || f.chunks.length !== Math.ceil(f.bytes / CHUNK) || f.chunks.some(x => !/^[a-f0-9]{64}\.part$/.test(x))) throw new Error('invalid release file record');
  return m;
}
async function serve(request, env, origin, file) {
  const etag = `"${file.sha256}"`;
  const rangeHeader = request.headers.has('if-range') && request.headers.get('if-range') !== etag ? null : request.headers.get('range');
  const range = rangeHeader ? parseRange(rangeHeader, file.bytes) : null;
  if (rangeHeader && !range) return new Response(null, { status: 416, headers: { 'content-range': `bytes */${file.bytes}`, 'accept-ranges': 'bytes' } });
  const [start, end] = range ?? [0, file.bytes - 1];
  const status = range ? 206 : 200;
  const filename = file.path.split('/').at(-1);
  const fallbackName = /^[\x20-\x7e]+$/.test(filename) ? filename : 'download.md';
  const headers = { 'content-type': file.type || 'application/octet-stream', 'content-length': String(file.bytes ? end - start + 1 : 0), 'content-disposition': `attachment; filename="${fallbackName}"; filename*=UTF-8''${encodeURIComponent(filename)}`, 'accept-ranges': 'bytes', etag, 'x-content-type-options': 'nosniff', 'x-content-sha256': file.sha256, 'cache-control': 'public, max-age=300' };
  if (range) headers['content-range'] = `bytes ${start}-${end}/${file.bytes}`;
  if (request.method === 'HEAD' || !file.bytes) return new Response(null, { status, headers });
  let pos = start;
  const body = new ReadableStream({ async pull(c) {
    if (pos > end) { c.close(); return; }
    const index = Math.floor(pos / CHUNK), offset = pos % CHUNK;
    const r = await env.ASSETS.fetch(new Request(origin + '/chunks/' + file.chunks[index]));
    if (!r.ok || !r.body) { c.error(new Error('missing release chunk')); return; }
    const reader = r.body.getReader(); let skipped = 0;
    try {
      const expectedChunkBytes = Math.min(CHUNK, file.bytes - index * CHUNK);
      while (true) { const x = await reader.read(); if (x.done) { if (skipped !== expectedChunkBytes) throw new Error('truncated release chunk'); break; }
        if (skipped + x.value.length <= offset) { skipped += x.value.length; continue; }
        const from = Math.max(0, offset - skipped), take = Math.min(x.value.length - from, end - pos + 1);
        if (take > 0) { c.enqueue(x.value.subarray(from, from + take)); pos += take; }
        if (pos > end) { await reader.cancel(); break; }
        skipped += x.value.length;
      }
      if (skipped > expectedChunkBytes) throw new Error('oversized release chunk');
      if (pos <= end && pos < (index + 1) * CHUNK) throw new Error('truncated release chunk');
    } catch (e) { c.error(e); }
  } });
  // Workers 对普通 ReadableStream 不保留 Content-Length；固定流保证浏览器有进度总量。
  if (typeof FixedLengthStream !== 'undefined') {
    const fixed = new FixedLengthStream(end - start + 1);
    body.pipeTo(fixed.writable).catch(() => {});
    return new Response(fixed.readable, { status, headers });
  }
  return new Response(body, { status, headers });
}
export default { async fetch(request, env) {
  const url = new URL(request.url);
  let path;
  try { path = decodeURIComponent(url.pathname); } catch { return responseError(400, 'Invalid path'); }
  if (!['GET', 'HEAD'].includes(request.method)) return responseError(405, 'Method not allowed');
  if (path === '/uninstall') return uninstallResponse(request.method);
  if (path === '/api/health') {
    try { const m = await readManifest(env, url.origin); return Response.json({ ok: true, version: m.version, files: m.files.map(({ path, bytes, sha256 }) => ({ path, bytes, sha256 })) }); }
    catch { return responseError(503, 'Release manifest unavailable'); }
  }
  if (path === '/') {
    try { const m = await readManifest(env, url.origin); const link = (label, p) => `<li><a href="${p}">${label}</a></li>`; return new Response(`<!doctype html><meta charset="utf-8"><title>Notion2DingDing 下载</title><h1>Notion2DingDing v${m.version}</h1><ul>${m.files.map(f => link(f.id === 'installer' ? 'Windows 安装器' : f.id === 'fallback' ? '备用安装包' : f.id === 'edge' ? 'Edge 扩展包' : f.id === 'checksums' ? 'SHA-256 校验和' : f.id.startsWith('mirror:') ? f.path.split('/').at(-1) : f.id, f.path)).join('')}</ul>`, { headers: { 'content-type': 'text/html; charset=utf-8' } }); } catch { return responseError(503, 'Release manifest unavailable'); }
  }
  try {
    const m = await readManifest(env, url.origin);
    const file = m.files.find(x => x.path === path);
    if (!file) return responseError(404, 'Not found');
    return await serve(request, env, url.origin, file);
  } catch { return responseError(503, 'Release unavailable'); }
} };
