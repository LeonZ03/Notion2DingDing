import assert from "node:assert/strict";
import test from "node:test";

import {
  createRequest,
  isNativeResponse,
  PROTOCOL_VERSION,
} from "../../dist/edge-extension/protocol.js";
import {
  getNotionPageIdentity,
  isSupportedNotionURL,
  requiresOfficialHTMLExport,
  taskBelongsToCurrentPage,
} from "../../dist/edge-extension/page-policy.js";
import {
  evaluateCompatibility,
  INSTALLER_URL,
  isVersionAtLeast,
} from "../../dist/edge-extension/compatibility.js";

test("createRequest creates a versioned request", () => {
  const request = createRequest("health.check", {});

  assert.equal(request.protocolVersion, PROTOCOL_VERSION);
  assert.equal(request.method, "health.check");
  assert.ok(request.requestId.length > 0);
});

test("isNativeResponse rejects incompatible responses", () => {
  assert.equal(
    isNativeResponse({ protocolVersion: 2, requestId: "1", ok: true }),
    false,
  );
  assert.equal(
    isNativeResponse({ protocolVersion: 1, requestId: "1", ok: true }),
    true,
  );
});

test("current-page policy only recognizes HTTPS Notion pages and still requires export", () => {
  assert.equal(isSupportedNotionURL("https://www.notion.com/workspace/page"), true);
  assert.equal(isSupportedNotionURL("https://notion.com/workspace/page"), true);
  assert.equal(isSupportedNotionURL("https://app.notion.com/p/page-id"), true);
  assert.equal(isSupportedNotionURL("https://www.notion.so/workspace/page"), true);
  assert.equal(isSupportedNotionURL("https://team.notion.so/workspace/page"), true);
  assert.equal(isSupportedNotionURL("https://notion.site/page"), true);
  assert.equal(isSupportedNotionURL("https://team.notion.site/page"), true);
  assert.equal(isSupportedNotionURL("http://www.notion.so/page"), false);
  assert.equal(isSupportedNotionURL("https://example.com/notion.so"), false);
  assert.equal(isSupportedNotionURL("chrome-extension://example/popup.html"), false);
  assert.equal(requiresOfficialHTMLExport(), true);
});

test("Notion task scope uses the stable page id and ignores query or slug changes", () => {
  const compact = "3b532b9e112580139024f2612a2daf17";
  assert.equal(
    getNotionPageIdentity(`https://app.notion.com/p/8-18-8-22-${compact}?v=1#part`),
    compact,
  );
  assert.equal(
    getNotionPageIdentity("https://www.notion.so/workspace/3b532b9e-1125-8013-9024-f2612a2daf17"),
    compact,
  );
  assert.equal(
    getNotionPageIdentity("https://app.notion.com/p/other-page-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  );
  assert.equal(getNotionPageIdentity("https://example.com/page"), undefined);
  assert.equal(taskBelongsToCurrentPage(compact, compact), true);
  assert.equal(taskBelongsToCurrentPage(compact, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), false);
  assert.equal(taskBelongsToCurrentPage(compact, undefined), false);
});

test("release compatibility distinguishes install, upgrade and ready states", () => {
  assert.equal(isVersionAtLeast("0.3.3", "0.3.3"), true);
  assert.equal(isVersionAtLeast("0.4.0", "0.3.3"), true);
  assert.equal(isVersionAtLeast("0.3.2", "0.3.3"), false);
  assert.match(INSTALLER_URL, /releases\/latest\/download\/Notion2DingDing-Setup\.exe$/u);

  const base = {
    hostVersion: "0.3.3",
    protocolVersion: 1,
    platform: "windows/amd64",
    capabilities: [
      "health.check",
      "local.open",
      "migration.inspect",
      "migration.start",
      "migration.status",
      "migration.cancel",
    ],
    localTool: {
      installed: true,
      version: "0.1.0",
      ready: true,
      authenticated: true,
      configured: true,
      message: "ready",
    },
  };
  assert.deepEqual(evaluateCompatibility(base), { compatible: true });
  assert.equal(evaluateCompatibility({ ...base, localTool: { ...base.localTool, installed: false } }).action, "install");
  assert.equal(evaluateCompatibility({ ...base, hostVersion: "0.3.2" }).action, "upgrade");
  assert.equal(evaluateCompatibility({ ...base, capabilities: ["health.check"] }).action, "upgrade");
});
