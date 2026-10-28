import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

const origin = 'https://notion2dingding.leonz03.dpdns.org';
const expected = JSON.parse(readFileSync(new URL('../dist/download-site/public/release-manifest.json', import.meta.url), 'utf8'));
async function get(path, options = {}) {
  const response = await fetch(origin + path, { redirect: 'error', signal: AbortSignal.timeout(180_000), ...options });
  assert.ok(response.ok, `${path}: HTTP ${response.status}`);
  return response;
}
const health = await (await get('/api/health')).json();
assert.equal(health.version, expected.version);
assert.deepEqual(health.files, expected.files.map(({ path, bytes, sha256 }) => ({ path, bytes, sha256 })));
// 有界并发，完整消费响应体；不将用户内容或程序副本写入磁盘。
const selectedPaths = process.argv.slice(2);
const queue = expected.files.filter(file => !selectedPaths.length || selectedPaths.includes(file.path));
const fileCount = queue.length;
async function consume() {
  for (let file; (file = queue.shift());) {
    let verified = false;
    for (let attempt = 1; attempt <= 3 && !verified; attempt++) {
      try {
        const response = await get(file.path);
        const contentLength = response.headers.get('content-length');
        // Cloudflare 可压缩文本附件，压缩响应不携带未压缩 Content-Length。
        if (contentLength !== null) assert.equal(Number(contentLength), file.bytes);
        else assert.ok(response.headers.has('content-encoding'), `${file.path}: missing length without encoding`);
        const digest = createHash('sha256');
        let received = 0;
        for await (const chunk of response.body) { received += chunk.length; digest.update(chunk); }
        assert.equal(received, file.bytes);
        assert.equal(digest.digest('hex'), file.sha256);
        console.log(JSON.stringify({ path: file.path, bytes: received, sha256Verified: true, redirect: false }));
        verified = true;
      } catch (error) { if (attempt === 3) throw error; }
    }
  }
}
await Promise.all([consume(), consume()]);
const node = expected.files.find(x => x.path.endsWith('node-v24.16.0-win-x64.zip'));
const source = readFileSync(new URL('../dist/mirror/node-v24.16.0-win-x64.zip', import.meta.url));
const start = expected.chunkBytes - 16, end = expected.chunkBytes + 16;
const range = await get(node.path, { headers: { Range: `bytes=${start}-${end}` } });
assert.equal(range.status, 206);
assert.equal(range.headers.get('content-range'), `bytes ${start}-${end}/${node.bytes}`);
assert.deepEqual(Buffer.from(await range.arrayBuffer()), source.subarray(start, end + 1));
console.log(JSON.stringify({ success: true, version: health.version, files: fileCount, crossChunkRangeVerified: true }));
