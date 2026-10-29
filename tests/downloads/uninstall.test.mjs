import assert from 'node:assert/strict';
import test from 'node:test';
import worker from '../../cloud/downloads/worker.mjs';
test('uninstall guidance works without manifest and offers truthful local cleanup steps', async()=>{
  const result=await worker.fetch(new Request('https://example.test/uninstall'),{});
  assert.equal(result.status,200);
  const html=await result.text();
  for(const text of ['已安装的应用','卸载 Notion2DingDing','-Action Uninstall','-RemoveDingtalkLogin','默认保留钉钉登录状态','共享','不会自动卸载','ms-settings:appsfeatures','/downloads/Notion2DingDing-Setup.exe']) assert.ok(html.includes(text),text);
  assert.doesNotMatch(html,/<(?:script|iframe|form)\b/i);
  assert.match(result.headers.get('content-security-policy'),/default-src 'none'/);
  assert.equal(result.headers.get('referrer-policy'),'no-referrer');
});
test('uninstall HEAD is bodyless and POST is rejected',async()=>{
  assert.equal(await (await worker.fetch(new Request('https://example.test/uninstall',{method:'HEAD'}),{})).text(),'');
  assert.equal((await worker.fetch(new Request('https://example.test/uninstall',{method:'POST'}),{})).status,405);
});
