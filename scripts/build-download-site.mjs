import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const source = join(root, 'dist'), release = join(source, 'release', `v${pkg.version}`), mirror = join(source, 'mirror');
const output = join(source, 'download-site', 'public'), chunksDir = join(output, 'chunks');
if (!statSync(release).isDirectory()) throw new Error(`Missing release directory: ${release}`);
const sha = b => createHash('sha256').update(b).digest('hex');
const installerSource = readFileSync(join(root, 'scripts/install-release.ps1'), 'utf8');
const runtimePins = [...installerSource.matchAll(/-ArchiveName '([^']+)' -Sha256 '([A-F0-9]{64})'/g)];
if (runtimePins.length !== 3) throw new Error('Installer runtime pins are missing');
for (const [, filename, digest] of runtimePins) {
  if (sha(readFileSync(join(mirror, filename))) !== digest.toLowerCase()) throw new Error(`Runtime SHA-256 mismatch: ${filename}`);
}
rmSync(join(source, 'download-site'), { recursive: true, force: true }); mkdirSync(chunksDir, { recursive: true });
const records = [];
function add(id, name, file, type) {
  const data = readFileSync(file), chunks = [];
  for (let offset = 0; offset < data.length; offset += 8 * 1024 * 1024) {
    const bytes = data.subarray(offset, Math.min(offset + 8 * 1024 * 1024, data.length)), digest = sha(bytes), chunkName = `${digest}.part`;
    writeFileSync(join(chunksDir, chunkName), bytes); chunks.push(chunkName);
  }
  records.push({ id, path: `/downloads/${name}`, bytes: data.length, sha256: sha(data), chunks, type });
}
add('installer', 'Notion2DingDing-Setup.exe', join(release, 'Notion2DingDing-Setup.exe'), 'application/vnd.microsoft.portable-executable');
add('fallback', `Notion2DingDing-Setup-Files-v${pkg.version}.zip`, join(release, `Notion2DingDing-Setup-Files-v${pkg.version}.zip`), 'application/zip');
add('edge', `Notion2DingDing-Edge-v${pkg.version}.zip`, join(release, `Notion2DingDing-Edge-v${pkg.version}.zip`), 'application/zip');
const mirrorNames = ['node-v24.16.0-win-x64.zip', 'pandoc-3.11-windows-x86_64.zip', 'dws-windows-amd64-1.0.59.zip', 'pandoc-3.11-source.tar.gz', 'node-v24.16.0-SHASUMS256.txt'];
for (const name of mirrorNames) { const file = join(mirror, name); if (statSync(file, { throwIfNoEntry: false })?.isFile()) add(`mirror:${name}`, name, file, name.endsWith('.txt') ? 'text/plain; charset=utf-8' : name.endsWith('.tar.gz') ? 'application/gzip' : 'application/zip'); }
for (const name of ['THIRD_PARTY_NOTICES.md', 'PRIVACY.md', '安装与升级说明.md']) { const file = join(release, name); if (statSync(file, { throwIfNoEntry: false })?.isFile()) add(`release:${name}`, name, file, name.endsWith('.md') ? 'text/markdown; charset=utf-8' : 'application/octet-stream'); }
const checksumLines = records.filter(x => x.id !== 'checksums').map(x => `${x.sha256}  ${x.path.slice('/downloads/'.length)}`);
const checksumBytes = Buffer.from(checksumLines.join('\n') + '\n');
const checksumPath = join(output, 'checksums.sha256'); writeFileSync(checksumPath, checksumBytes);
const checksumChunks = []; for (let offset = 0; offset < checksumBytes.length; offset += 8 * 1024 * 1024) { const part = checksumBytes.subarray(offset, Math.min(offset + 8 * 1024 * 1024, checksumBytes.length)), digest = sha(part); writeFileSync(join(chunksDir, `${digest}.part`), part); checksumChunks.push(`${digest}.part`); }
records.push({ id: 'checksums', path: '/downloads/checksums.sha256', bytes: checksumBytes.length, sha256: sha(checksumBytes), chunks: checksumChunks, type: 'text/plain; charset=utf-8' });
writeFileSync(join(output, 'release-manifest.json'), JSON.stringify({ version: pkg.version, chunkBytes: 8 * 1024 * 1024, files: records }, null, 2) + '\n');
const labels = { installer: 'Windows 安装器', fallback: '备用安装包', edge: 'Edge 扩展包', checksums: 'SHA-256 校验和' };
writeFileSync(join(output, 'index.html'), `<!doctype html><meta charset="utf-8"><title>Notion2DingDing 下载</title><h1>Notion2DingDing v${pkg.version}</h1><ul>${records.map(x => `<li><a href="${x.path}">${labels[x.id] || x.path.slice('/downloads/'.length)}</a></li>`).join('')}</ul><p><a href="/api/health">下载状态与文件清单</a></p>\n`);
console.log(JSON.stringify({ output, version: pkg.version, files: records.length, chunks: records.reduce((n, f) => n + f.chunks.length, 0) }));
