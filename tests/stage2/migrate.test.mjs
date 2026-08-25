import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  rmdirSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(testDirectory, "..", "..");
const cliPath = path.join(repoRoot, "scripts", "migrate-notion-to-dingtalk.mjs");
const fakeDwsPath = path.join(testDirectory, "fake-dws.mjs");
const fixturePath = path.join(repoRoot, "tests", "fixtures", "notion-export");
const runtimeRoot = path.join(repoRoot, "artifacts", "stage2-tests");
const stateRoot = path.join(runtimeRoot, "state");
const temporaryRoot = path.join(runtimeRoot, "tool-temp");
const runNonce = `${process.pid}-${Date.now()}`;

function parseResult(stdout) {
  assert.notEqual(stdout.trim(), "", "迁移命令必须输出 JSON");
  return JSON.parse(stdout);
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

function runMigration(name, scenario, extraArgs = [], input = fixturePath) {
  const workDirectory = path.join(runtimeRoot, name);
  rmSync(workDirectory, { recursive: true, force: true });
  mkdirSync(workDirectory, { recursive: true });
  const logPath = path.join(workDirectory, "dws-calls.jsonl");
  const outputPath = path.join(workDirectory, "output.docx");
  const result = spawnSync(
    process.execPath,
    [
      cliPath,
      "--input",
      input,
      "--folder",
      "fake-folder-node",
      "--name",
      `阶段 2 自动验收-${name}-${runNonce}`,
      "--output",
      outputPath,
      "--dws-path",
      fakeDwsPath,
      "--force",
      ...extraArgs,
    ],
    {
      cwd: repoRoot,
      encoding: "utf8",
      env: {
        ...process.env,
        N2DD_FAKE_SCENARIO: scenario,
        N2DD_FAKE_LOG: logPath,
        N2DD_STATE_DIRECTORY: stateRoot,
        N2DD_TEMP_DIRECTORY: temporaryRoot,
      },
      maxBuffer: 32 * 1024 * 1024,
      windowsHide: true,
    },
  );
  assert.equal(existsSync(outputPath), false, `${name} 结束后仍残留中间 DOCX`);
  assert.equal(existsSync(temporaryRoot), false, `${name} 结束后仍残留临时任务目录`);
  return {
    ...result,
    data: parseResult(result.stdout),
    calls: readCalls(logPath),
    workDirectory,
    outputPath,
  };
}

function assertMinimalState(result) {
  assert.ok(result.data.stateRecord, "必须返回最小任务状态路径");
  assert.ok(existsSync(result.data.stateRecord), "最小任务状态必须存在");
  const text = readFileSync(result.data.stateRecord, "utf8");
  for (const forbidden of [
    fixturePath,
    "output.docx",
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

test.before(() => {
  assert.equal(process.platform, "win32", "阶段 2 MVP 自动化验收必须在 Windows 上运行");
  assert.ok(existsSync(fixturePath), "阶段 1 Notion 夹具必须存在");
  mkdirSync(runtimeRoot, { recursive: true });
});

test("一条命令完成转换、导入和真实 URL 回读", () => {
  const result = runMigration("success", "success");
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.data.success, true);
  assert.equal(result.data.status, "success");
  assert.equal(result.data.remote.documentUrl, "https://alidocs.dingtalk.com/i/nodes/fake-stage2-node");
  assert.equal(result.data.checks.expectedImageCount, 2);
  assert.equal(result.data.checks.readbackImageCount, 2);
  assert.equal(result.data.local.docx.permanentlyDeleted, true);
  assert.equal(result.data.cleanup.verified, true);
  assert.equal(result.calls.filter((call) => call.args.includes("+import")).length, 1);
  assert.equal(result.calls.filter((call) => call.args.includes("+fetch")).length, 1);
  assertMinimalState(result);
});

test("损坏 ZIP 在写入钉钉前失败", () => {
  const corruptZip = path.join(runtimeRoot, "corrupt.zip");
  writeFileSync(corruptZip, Buffer.from("not-a-zip", "utf8"));
  const result = runMigration("corrupt-zip", "success", [], corruptZip);
  assert.notEqual(result.status, 0);
  assert.equal(result.data.error.code, "CONVERSION_FAILED");
  assert.equal(result.calls.some((call) => call.args.includes("+import")), false);
  assert.equal(existsSync(result.data.stateRecord), false, "确定失败不应留下任务状态");
});

test("引用图片缺失时明确失败且不导入", () => {
  const copiedFixture = path.join(runtimeRoot, "missing-image-fixture");
  rmSync(copiedFixture, { recursive: true, force: true });
  cpSync(fixturePath, copiedFixture, { recursive: true });
  const image = readdirSync(copiedFixture, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith(".png"))
    .map((entry) => path.join(entry.parentPath, entry.name))
    .at(0);
  assert.ok(image && existsSync(image), `测试图片不存在：${image}`);
  unlinkSync(image);
  const result = runMigration("missing-image", "success", [], copiedFixture);
  assert.notEqual(result.status, 0);
  assert.equal(result.data.error.code, "CONVERSION_FAILED");
  assert.match(result.data.error.message, /缺失|不存在|missing/iu);
  assert.equal(result.calls.some((call) => call.args.includes("+import")), false);
});

test("未登录时在转换和导入前停止", () => {
  const result = runMigration("unauthenticated", "unauthenticated");
  assert.notEqual(result.status, 0);
  assert.equal(result.data.error.code, "DWS_NOT_AUTHENTICATED");
  assert.equal(result.calls.some((call) => call.args.includes("+import")), false);
});

test("目标无权限时返回明确错误且不误报成功", () => {
  const result = runMigration("permission", "permission");
  assert.notEqual(result.status, 0);
  assert.equal(result.data.success, false);
  assert.equal(result.data.error.code, "IMPORT_PERMISSION_DENIED");
  assert.equal(result.calls.filter((call) => call.args.includes("+import")).length, 1);
  assert.equal(result.calls.some((call) => call.args.includes("+fetch")), false);
  assert.equal(existsSync(result.data.stateRecord), false, "权限失败不应留下任务状态");
});

test("写入状态未知时保留 taskId 并禁止自动重试", () => {
  const result = runMigration("unknown", "unknown");
  assert.notEqual(result.status, 0);
  assert.equal(result.data.status, "unknown");
  assert.equal(result.data.error.code, "IMPORT_COMMIT_UNKNOWN");
  assert.equal(result.data.remoteTaskId, "fake-unknown-task");
  assert.equal(result.calls.filter((call) => call.args.includes("+import")).length, 1);
  assert.equal(result.calls.some((call) => call.args.includes("+fetch")), false);
  assertMinimalState(result);

  const retry = runMigration("unknown", "unknown");
  assert.notEqual(retry.status, 0);
  assert.equal(retry.data.status, "unknown");
  assert.equal(retry.data.error.code, "PREVIOUS_COMMIT_UNKNOWN");
  assert.equal(retry.calls.length, 0, "未知写入状态不能再次调用 dws");
});

test("导入返回非 JSON 时按未知状态处理并锁止重试", () => {
  const result = runMigration("malformed-import", "malformed-import");
  assert.notEqual(result.status, 0);
  assert.equal(result.data.status, "unknown");
  assert.equal(result.data.error.code, "IMPORT_COMMIT_UNKNOWN");
  assert.equal(result.calls.filter((call) => call.args.includes("+import")).length, 1);
  assertMinimalState(result);

  const retry = runMigration("malformed-import", "malformed-import");
  assert.notEqual(retry.status, 0);
  assert.equal(retry.data.error.code, "PREVIOUS_COMMIT_UNKNOWN");
  assert.equal(retry.calls.length, 0, "非结构化导入结果不能自动重试");
});

test("目标目录与知识库参数必须且只能选择一个", () => {
  const result = spawnSync(process.execPath, [cliPath, "--input", fixturePath], {
    cwd: repoRoot,
    encoding: "utf8",
    windowsHide: true,
  });
  const data = parseResult(result.stdout);
  assert.notEqual(result.status, 0);
  assert.equal(data.error.code, "ARGUMENT_ERROR");
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
    assert.equal(existsSync(runtimeRoot), false, "阶段 2 测试数据必须永久删除");
  }
});
