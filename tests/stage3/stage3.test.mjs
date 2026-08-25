import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  rmdirSync,
  unlinkSync,
} from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(testDirectory, "..", "..");
const cliPath = path.join(repoRoot, "scripts", "migrate-notion-to-dingtalk.mjs");
const verifyPath = path.join(repoRoot, "scripts", "test-docx-assets.ps1");
const fakeDwsPath = path.join(repoRoot, "tests", "stage2", "fake-dws.mjs");
const fixtureRoot = path.join(repoRoot, "tests", "fixtures", "stage3");
const longFixture = path.join(fixtureRoot, "long-page");
const multiImageFixture = path.join(fixtureRoot, "multi-image");
const subpageFixture = path.join(fixtureRoot, "subpages-special");
const runtimeRoot = path.join(repoRoot, "artifacts", "stage3-tests");
const stateRoot = path.join(runtimeRoot, "state");
const temporaryRoot = path.join(runtimeRoot, "tool-temp");
const powershell = path.join(
  process.env.SystemRoot ?? "C:\\Windows",
  "System32",
  "WindowsPowerShell",
  "v1.0",
  "powershell.exe",
);
const runNonce = process.pid + "-" + Date.now();

function parseJson(stdout, label) {
  const trimmed = stdout.trim();
  assert.notEqual(trimmed, "", label + " 必须输出 JSON");
  try {
    return JSON.parse(trimmed);
  } catch {
    for (let index = trimmed.indexOf("{"); index >= 0; index = trimmed.indexOf("{", index + 1)) {
      try {
        return JSON.parse(trimmed.slice(index));
      } catch {
        // 继续寻找结构化结果。
      }
    }
  }
  assert.fail(label + " 返回了无法解析的 JSON");
}

function readCalls(logPath) {
  if (!existsSync(logPath)) {
    return [];
  }
  return readFileSync(logPath, "utf8")
    .trim()
    .split(/\r?\n/u)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function runMigration(name, fixture, imageCount, options = {}) {
  const workDirectory = path.join(runtimeRoot, name);
  rmSync(workDirectory, { recursive: true, force: true });
  mkdirSync(workDirectory, { recursive: true });
  const logPath = path.join(workDirectory, "dws-calls.jsonl");
  const outputPath = path.join(workDirectory, "output.docx");
  const capturePath = path.join(workDirectory, "test-capture.docx");
  const title = "阶段 3 自动验收-" + name + "-" + runNonce;
  const args = [
    cliPath,
    "--input",
    fixture,
    "--folder",
    "fake-stage3-folder",
    "--name",
    title,
    "--dws-path",
    fakeDwsPath,
  ];
  if (!options.defaultOutput) {
    args.push("--output", outputPath);
  }
  if (options.force) {
    args.push("--force");
  }
  const result = spawnSync(process.execPath, args, {
    cwd: repoRoot,
    encoding: "utf8",
    env: {
      ...process.env,
      N2DD_FAKE_SCENARIO: options.scenario ?? "success",
      N2DD_FAKE_IMAGE_COUNT: String(imageCount),
      N2DD_FAKE_LOG: logPath,
      N2DD_FAKE_CAPTURE_DOCX: capturePath,
      N2DD_STATE_DIRECTORY: stateRoot,
      N2DD_TEMP_DIRECTORY: temporaryRoot,
    },
    maxBuffer: 64 * 1024 * 1024,
    windowsHide: true,
  });
  assert.equal(existsSync(outputPath), false, `${name} 结束后仍残留中间 DOCX`);
  assert.equal(existsSync(temporaryRoot), false, `${name} 结束后仍残留临时任务目录`);
  return {
    ...result,
    data: parseJson(result.stdout, "迁移命令"),
    calls: readCalls(logPath),
    workDirectory,
    capturePath,
  };
}

function assertMinimalState(result) {
  assert.ok(result.data.stateRecord, "必须返回最小任务状态路径");
  assert.ok(existsSync(result.data.stateRecord), "最小任务状态必须存在");
  const text = readFileSync(result.data.stateRecord, "utf8");
  for (const forbidden of [
    fixtureRoot,
    "output.docx",
    "test-capture.docx",
    '"input"',
    '"entry"',
    '"documents"',
    '"assets"',
    '"mappings"',
    '"warnings"',
  ]) {
    assert.equal(text.includes(forbidden), false, `最小状态泄露了内容字段：${forbidden}`);
  }
}

function verifyDocx(docxPath, expectedImages, requiredText) {
  const result = spawnSync(
    powershell,
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      verifyPath,
      "-DocxPath",
      docxPath,
      "-ExpectedImageCount",
      String(expectedImages),
      "-RequiredText",
      requiredText,
    ],
    {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
      windowsHide: true,
    },
  );
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return parseJson(result.stdout, "DOCX 验证");
}

test.before(() => {
  assert.equal(process.platform, "win32", "阶段 3 自动化验收必须在 Windows 上运行");
  for (const fixture of [longFixture, multiImageFixture, subpageFixture]) {
    assert.ok(existsSync(fixture), "固定夹具不存在：" + fixture);
  }
  mkdirSync(runtimeRoot, { recursive: true });
});

test("中文、URL 编码、嵌套子页面和特殊块生成明确映射报告", () => {
  const result = runMigration("subpages-special", subpageFixture, 2, {
    defaultOutput: true,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.data.success, true);
  assert.equal(result.data.local.documentCount, 3);
  assert.equal(result.data.local.subpageCount, 2);
  assert.equal(result.data.local.documents.length, 3);
  assert.match(result.data.local.documents[2].relativePath, /孙页面/u);

  const audit = result.data.local.imageAudit;
  assert.equal(audit.sourceReferenceCount, 2);
  assert.equal(audit.localizedFileCount, 2);
  assert.equal(audit.localizedAssetCount, 2);
  assert.equal(audit.outputMediaCount, 2);
  assert.equal(audit.outputImageOccurrenceCount, 2);
  assert.equal(audit.hashesComplete, true);
  assert.equal(result.data.checks.imageAuditMatches, true);
  assert.equal(result.data.local.docx.permanentlyDeleted, true);
  assert.equal(result.data.cleanup.verified, true);
  assertMinimalState(result);

  const mappings = result.data.local.mappings;
  assert.equal(mappings.callout.detectedCount, 1);
  assert.equal(mappings.callout.status, "mapped");
  assert.equal(mappings.toggle.detectedCount, 1);
  assert.equal(mappings.toggle.status, "degraded");
  assert.equal(mappings.columns.status, "source_flattened");
  assert.equal(mappings.database.detectedCount, 1);
  assert.equal(mappings.database.status, "degraded");
  assert.match(mappings.database.files[0].sha256, /^[A-F0-9]{64}$/u);

  const warningCodes = new Set(result.data.local.warnings.map((warning) => warning.code));
  for (const code of [
    "SUBPAGES_APPENDED",
    "CALLOUT_TO_BLOCKQUOTE",
    "TOGGLE_EXPANDED",
    "DATABASE_TO_CSV_NOTE",
    "COLUMNS_LINEARIZED_BY_EXPORT",
  ]) {
    assert.ok(warningCodes.has(code), "缺少降级或映射报告：" + code);
  }

  for (const marker of [
    "PARENT-FINAL",
    "CHILD-FINAL",
    "GRANDCHILD-FINAL",
    "Callout",
    "Toggle",
  ]) {
    verifyDocx(result.capturePath, 2, marker);
  }
});

test("长篇固定夹具完整进入 DOCX 并输出规模指标", () => {
  const result = runMigration("long-page", longFixture, 0);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.data.success, true);
  assert.ok(result.data.local.sourceCharacters >= 2500);
  assert.equal(result.data.local.documentCount, 1);
  assert.equal(result.data.local.imageAudit.sourceReferenceCount, 0);
  assert.equal(result.data.local.imageAudit.outputImageOccurrenceCount, 0);

  const verification = verifyDocx(result.capturePath, 0, "L30-FINAL");
  assert.ok(verification.visibleTextCharacters >= 2200);
  assert.ok(verification.paragraphCount >= 80);
  verifyDocx(result.capturePath, 0, "L15");
  verifyDocx(result.capturePath, 0, "长篇文档稳定性验证");
});

test("八个图片引用按 SHA-256 去重并可核对全部输出位置", () => {
  const first = runMigration("multi-image", multiImageFixture, 8);
  assert.equal(first.status, 0, first.stderr);
  assert.equal(first.data.success, true);
  const audit = first.data.local.imageAudit;
  assert.equal(audit.sourceReferenceCount, 8);
  assert.equal(audit.localizedFileCount, 8);
  assert.equal(audit.localizedAssetCount, 2);
  assert.equal(audit.outputMediaCount, 2);
  assert.equal(audit.outputImageOccurrenceCount, 8);
  assert.equal(first.data.local.assets.length, 8);
  assert.equal(new Set(first.data.local.assets.map((asset) => asset.sha256)).size, 2);
  assert.ok(first.data.local.assets.every((asset) => /^[A-F0-9]{64}$/u.test(asset.sha256)));
  assert.equal(first.data.checks.expectedImageCount, 8);
  assert.equal(first.data.checks.readbackImageCount, 8);

  const verification = verifyDocx(first.capturePath, 2, "M08-FINAL");
  assert.equal(verification.imageDrawingCount, 8);

  const repeated = runMigration("multi-image", multiImageFixture, 8);
  assert.equal(repeated.status, 0, repeated.stderr);
  assert.equal(repeated.data.reused, true);
  assert.equal(repeated.calls.length, 0, "相同成功任务不应再次调用 dws");
});

test("缺失的嵌套子页面在调用钉钉前明确失败", () => {
  const copiedFixture = path.join(runtimeRoot, "missing-subpage-fixture");
  rmSync(copiedFixture, { recursive: true, force: true });
  cpSync(subpageFixture, copiedFixture, { recursive: true });
  const missingPage = path.join(
    copiedFixture,
    "父页面 44444444444444444444444444444444",
    "子页面 55555555555555555555555555555555",
    "孙页面 66666666666666666666666666666666.md",
  );
  assert.ok(existsSync(missingPage));
  unlinkSync(missingPage);

  const result = runMigration("missing-subpage", copiedFixture, 2);
  assert.notEqual(result.status, 0);
  assert.equal(result.data.error.code, "CONVERSION_FAILED");
  assert.match(result.data.error.message, /子页面缺失/u);
  assert.equal(result.calls.some((call) => call.args.includes("+import")), false);
  assert.equal(existsSync(result.data.stateRecord), false, "确定失败不应留下任务状态");
});

test.after(() => {
  if (process.env.N2DD_KEEP_TEST_ARTIFACTS !== "1") {
    rmSync(runtimeRoot, { recursive: true, force: true });
    try {
      rmdirSync(path.dirname(runtimeRoot));
    } catch (error) {
      if (!["ENOENT", "ENOTEMPTY", "EEXIST"].includes(error.code)) {
        throw error;
      }
    }
    assert.equal(existsSync(runtimeRoot), false, "阶段 3 测试数据必须永久删除");
  }
});
