import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker from '../../cloud/downloads/worker.mjs';
const CHUNK = 8 * 1024 * 1024;
const bytes = new Uint8Array(CHUNK + 32); for (let i = 0; i < bytes.length; i++) bytes[i] = i % 251;
const parts = [bytes.slice(0, CHUNK), bytes.slice(CHUNK)];
const partNames = parts.map(b => createHash('sha256').update(b).digest('hex') + '.part');
const hash = createHash('sha256').update(bytes).digest('hex');
const manifest = { version: '0.1.0', files: [{ id: 'installer', path: '/downloads/Notion2DingDing-Setup.exe', bytes: bytes.length, sha256: hash, chunks: partNames, type: 'application/octet-stream' }, { id: 'mirror:node', path: '/downloads/node-v24.16.0-win-x64.zip', bytes: parts[1].length, sha256: createHash('sha256').update(parts[1]).digest('hex'), chunks: [partNames[1]], type: 'application/zip' }] };
function env(m = manifest, truncate = false, omit = -1) { return { ASSETS: { async fetch(req) { const p = new URL(req.url).pathname; if (p === '/release-manifest.json') return Response.json(m); const index = partNames.findIndex(n => p === '/chunks/' + n); if (index >= 0 && index !== omit) return new Response(truncate && index === 1 ? parts[index].slice(0, 10) : parts[index]); return new Response(null, { status: 404 }); } } }; }
const req = (path, method = 'GET', headers = {}, e = env()) => worker.fetch(new Request('https://example.test' + path, { method, headers }), e);
test('完整下载与 HEAD 返回长度及哈希', async () => { const r = await req(manifest.files[0].path); assert.equal(r.status, 200); assert.equal(Number(r.headers.get('content-length')), bytes.length); assert.equal(r.headers.get('x-content-sha256'), hash); assert.deepEqual(new Uint8Array(await r.arrayBuffer()), bytes); const h = await req(manifest.files[0].path, 'HEAD'); assert.equal(h.status, 200); assert.equal(Number(h.headers.get('content-length')), bytes.length); });
test('跨分片 Range 下载正确字节', async () => { const start = CHUNK - 5, end = CHUNK + 6; const r = await req(manifest.files[0].path, 'GET', { range: `bytes=${start}-${end}` }); assert.equal(r.status, 206); assert.equal(r.headers.get('content-range'), `bytes ${start}-${end}/${bytes.length}`); assert.deepEqual(new Uint8Array(await r.arrayBuffer()), bytes.slice(start, end + 1)); });
test('manifest 中白名单镜像文件可下载', async () => { const r = await req(manifest.files[1].path); assert.equal(r.status, 200); assert.deepEqual(new Uint8Array(await r.arrayBuffer()), parts[1]); });
test('未知路径返回 404', async () => { assert.equal((await req('/downloads/nope')).status, 404); });
test('读取时发现缺失分片则拒绝响应体', async () => { const r = await req(manifest.files[0].path, 'GET', {}, env(manifest, false, 1)); await assert.rejects(() => r.arrayBuffer()); });
test('截断分片拒绝响应体且不会卡住', async () => { const r = await req(manifest.files[0].path, 'GET', {}, env(manifest, true)); await assert.rejects(() => r.arrayBuffer()); });
test('manifest 中的路径穿越被拒绝', async () => { const bad = structuredClone(manifest); bad.files[0].path = '/downloads/../secret'; assert.equal((await req(manifest.files[0].path, 'GET', {}, env(bad))).status, 503); });

test('中文安装说明不导致整份 manifest 失效', async () => { const m = structuredClone(manifest); m.files[1].path = '/downloads/安装与升级说明.md'; const r = await req('/downloads/安装与升级说明.md', 'GET', {}, env(m)); assert.equal(r.status, 200); assert.match(r.headers.get('content-disposition'), /filename\*=UTF-8/); assert.deepEqual(new Uint8Array(await r.arrayBuffer()), parts[1]); });

test('过期 If-Range 返回完整新文件，非法 Range 返回 416', async () => { const r = await req(manifest.files[0].path, 'GET', { range: 'bytes=1-3', 'if-range': '"old"' }); assert.equal(r.status, 200); assert.deepEqual(new Uint8Array(await r.arrayBuffer()), bytes); assert.equal((await req(manifest.files[0].path, 'GET', { range: 'bytes=999999999-' })).status, 416); });
