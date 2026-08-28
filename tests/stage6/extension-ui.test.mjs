import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import test from "node:test";

const root = resolve(import.meta.dirname, "..", "..");
const extension = join(root, "dist", "edge-extension");

test("stage 6 popup exposes preflight, progress, cancel, recovery and result UI", async () => {
  const html = await readFile(join(extension, "popup.html"), "utf8");
  const css = await readFile(join(extension, "popup.css"), "utf8");
  const popup = await readFile(join(extension, "popup.js"), "utf8");

  for (const id of [
    "host-status",
    "local-setup",
    "local-setup-download",
    "local-setup-release",
    "settings-panel",
    "migration-panel",
    "auth-status",
    "target-status",
    "select-export",
    "export-summary",
    "export-summary-title",
    "export-summary-meta",
    "previous-export",
    "previous-export-link",
    "document-title",
    "task-panel",
    "progress-bar",
    "cancel-task",
    "recovery-panel",
    "recovery-action",
    "result-panel",
    "result-link",
  ]) {
    assert.match(html, new RegExp(`id=["']${id}["']`, "u"), `missing popup control: ${id}`);
  }
  assert.match(html, /独立迁移工具/u);
  assert.match(html, /无隶属或背书关系/u);
  assert.match(html, /运行安装包后回到这里/u);
  assert.equal((html.match(/name="subpage-mode"/gu) ?? []).length, 2);
  assert.match(html, /id="subpage-mode-inline"[^>]*type="radio"[^>]*checked/u);
  assert.match(html, /id="subpage-mode-tree"[^>]*type="radio"/u);
  assert.doesNotMatch(html, /<select[^>]*id="subpage-mode"/u);
  assert.match(css, /\.subpage-mode-input:checked\s*\{[^}]*border-color:\s*#2383e2;[^}]*box-shadow:/su);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/u);
  assert.match(css, /body\s*\{[^}]*width:\s*400px;[^}]*min-width:\s*400px;/su);
  assert.doesNotMatch(css, /max-width:\s*100vw/u);
  assert.match(css, /\[hidden\]\s*\{\s*display:\s*none\s*!important/u);
  assert.match(popup, /native\.export\.transfer\.begin/u);
  assert.match(popup, /native\.export\.transfer\.chunk/u);
  assert.match(popup, /native\.export\.transfer\.commit/u);
  assert.match(popup, /sendExportTransfer\(\s*"start"/u);
  assert.match(popup, /createNew:\s*true/u);
  assert.match(popup, /if \(activeTaskId !== taskId\)\s*return/u);
  assert.match(popup, /if \(exportSelectionStarted \|\| inspectingExport \|\| selectedExport\)\s*return/u);
  assert.doesNotMatch(popup, /已禁止重复导入/u);
  assert.match(popup, /此前已导出/u);
  assert.match(popup, /仍再次导出/u);
  assert.match(popup, /previous\.documentUrl/u);
  assert.match(popup, /evaluateCompatibility\(health\)/u);
  assert.match(popup, /showLocalSetup\("install"/u);
  assert.match(popup, /INSTALLER_URL/u);
  assert.match(popup, /selectedExport\s*=\s*\{\s*file,\s*contentBase64,\s*inspection\s*\}/u);
  assert.match(popup, /titleInput\.value\s*=\s*inspection\.title/u);
  assert.match(popup, /migrateButton\?\.addEventListener\("click",\s*\(\)\s*=>\s*void startMigration\(\)\)/u);
  assert.doesNotMatch(popup, /titleInput\.value\s*=\s*currentPage\.title/u);
  assert.match(html, />\s*开始转换\s*</u);
  assert.match(html, /选择后只预检/u);
  assert.match(html, /placeholder="请先选择导出包"[^>]*disabled/u);
  assert.match(popup, /native\.task\.status/u);
  assert.match(popup, /native\.task\.cancel/u);
  assert.match(popup, /chrome\.storage\.session/u);
  assert.match(popup, /sourcePageIdentity/u);
  assert.match(popup, /taskBelongsToCurrentPage\(storedTask\.sourcePageIdentity, currentPageIdentity\)/u);
  assert.match(popup, /本次写入状态未确认/u);
  assert.doesNotMatch(html, /环境与目标/u);
});

test("stage 6 manifest includes storage permission and all generated icon sizes", async () => {
  const manifest = JSON.parse(await readFile(join(extension, "manifest.json"), "utf8"));
  assert.ok(manifest.permissions.includes("storage"));
  assert.equal(manifest.name, "__MSG_extensionName__");
  assert.equal(manifest.description, "__MSG_extensionDescription__");
  assert.equal(manifest.default_locale, "zh_CN");
  assert.deepEqual(Object.keys(manifest.icons), ["16", "32", "48", "128"]);
  assert.deepEqual(Object.keys(manifest.action.default_icon), ["16", "32"]);

  const messages = JSON.parse(
    await readFile(join(extension, "_locales", "zh_CN", "messages.json"), "utf8"),
  );
  assert.equal(messages.extensionName.message, "Notion2DingDing");
  assert.match(messages.extensionDescription.message, /钉钉富文本文档/u);

  for (const size of [16, 32, 48, 128]) {
    const png = await readFile(join(extension, "icons", `icon-${size}.png`));
    assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
    assert.equal(png.readUInt32BE(16), size);
    assert.equal(png.readUInt32BE(20), size);
  }
  await assert.rejects(access(join(extension, "icons", "icon-master-v2.png")));
});

test("versioned schema contains asynchronous migration task envelopes", async () => {
  const schema = JSON.parse(await readFile(join(root, "protocol", "native-message.schema.json"), "utf8"));
  assert.ok(schema.$defs.migrationTaskParams);
  assert.ok(schema.$defs.migrationTaskSnapshot);
  assert.ok(schema.$defs.migrationExportInspection);
  assert.ok(schema.$defs.migrationPreviousExport);
  assert.equal(schema.$defs.migrationExportParams.properties.createNew.type, "boolean");
  assert.deepEqual(schema.$defs.migrationTaskSnapshot.properties.status.enum, [
    "queued",
    "running",
    "cancel_requested",
    "succeeded",
    "failed",
    "unknown",
    "cancelled",
  ]);
});
