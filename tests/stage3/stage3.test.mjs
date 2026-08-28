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
  writeFileSync,
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
  const title = options.title ?? "阶段 3 自动验收-" + name + "-" + runNonce;
  const args = [
    cliPath,
    "--input",
    fixture,
    options.workspace ? "--workspace" : "--folder",
    options.workspace ?? "fake-stage3-folder",
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
  if (options.subpages) {
    args.push("--subpages", options.subpages);
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
      ...(options.env ?? {}),
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

test("HTML 中的中文、URL 编码、嵌套子页面和特殊块生成明确映射报告", () => {
  const expectedSubpageLinks = [
    {
      sourcePageIndex: 0,
      label: "子页面入口",
      targetPageIndex: 1,
      targetTitle: "子页面",
    },
    {
      sourcePageIndex: 1,
      label: "孙页面入口",
      targetPageIndex: 2,
      targetTitle: "孙页面",
    },
  ];
  const result = runMigration("subpages-special", subpageFixture, 2, {
    defaultOutput: true,
    env: {
      N2DD_FAKE_SUBPAGE_LINKS: JSON.stringify(expectedSubpageLinks),
    },
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
  assert.equal(mappings.columns.status, "not_present");
  assert.equal(mappings.database.detectedCount, 1);
  assert.equal(mappings.database.status, "degraded");
  assert.match(mappings.database.files[0].sha256, /^[A-F0-9]{64}$/u);
  assert.equal(mappings.subpageLinks.detectedPageCount, 2);
  assert.equal(mappings.subpageLinks.detectedLinkCount, 2);
  assert.deepEqual(
    mappings.subpageLinks.links.map(({ sourcePageIndex, label, targetPageIndex, targetTitle }) => ({
      sourcePageIndex,
      label,
      targetPageIndex,
      targetTitle,
    })),
    expectedSubpageLinks,
  );
  assert.equal(mappings.subpageLinks.status, "preserved");
  assert.equal(mappings.subpageLinks.nativeRestore.nativeCount, 1);
  assert.equal(mappings.subpageLinks.nativeRestore.nativeItemCount, 2);
  assert.equal(mappings.subpageLinks.nativeRestore.updatedCount, 1);
  assert.equal(mappings.subpageLinks.nativeRestore.deletedCount, 1);
  assert.equal(mappings.subpageLinks.nativeRestore.verified, true);
  assert.equal(result.data.checks.expectedSubpageEntryCount, 2);
  assert.equal(result.data.checks.nativeSubpageTocCount, 1);
  assert.equal(result.data.checks.nativeSubpageTocItemCount, 2);
  assert.equal(result.data.checks.subpageTocMatches, true);
  const subpageUpdates = result.calls.filter((call) => {
    const elementIndex = call.args.indexOf("--element");
    return elementIndex >= 0 && call.args[call.args.indexOf("--block-id") + 1]
      ?.startsWith("fake-subpage-link-") &&
      call.args[elementIndex + 1].startsWith('["toc",');
  });
  assert.equal(subpageUpdates.length, 1);
  const tocElement = JSON.parse(
    subpageUpdates[0].args[subpageUpdates[0].args.indexOf("--element") + 1],
  );
  assert.equal(tocElement[0], "toc");
  assert.equal(tocElement[1].title, "子页面");
  assert.deepEqual(
    tocElement[1].content.map(({ text, anchorId, level }) => ({ text, anchorId, level })),
    [
      { text: "子页面", anchorId: "fake-subpage-heading-1", level: 2 },
      { text: "孙页面", anchorId: "fake-subpage-heading-2", level: 2 },
    ],
  );
  assert.equal(JSON.stringify(tocElement).includes('"data-type":"refer"'), false);
  const subpageDeletes = result.calls.filter((call) =>
    call.args?.[0] === "doc" && call.args?.[1] === "block" &&
    call.args?.[2] === "delete"
  );
  assert.equal(subpageDeletes.length, 1);
  assert.equal(subpageDeletes[0].args.includes("--yes"), true);
  assert.equal(
    subpageDeletes[0].args[subpageDeletes[0].args.indexOf("--block-id") + 1],
    "fake-subpage-link-2",
  );

  const warningCodes = new Set(result.data.local.warnings.map((warning) => warning.code));
  for (const code of [
    "SUBPAGES_APPENDED",
    "CALLOUT_CONTENT_PRESERVED",
    "TOGGLE_EXPANDED",
    "DATABASE_TO_CSV_NOTE",
  ]) {
    assert.ok(warningCodes.has(code), "缺少降级或映射报告：" + code);
  }

  for (const marker of [
    "PARENT-FINAL",
    "CHILD-FINAL",
    "GRANDCHILD-FINAL",
    "子页面",
    "孙页面",
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

test("递归文档树为每个 Notion 页面创建同名文件夹和独立文档并回填链接", () => {
  const title = "递归文档树自动验收-" + runNonce;
  const treeLinks = {
    [title]: [{ label: "子页面入口" }],
    子页面: [{ label: "孙页面入口" }],
    孙页面: [],
  };
  const first = runMigration("recursive-tree", subpageFixture, 0, {
    title,
    subpages: "tree",
    defaultOutput: true,
    env: {
      N2DD_FAKE_TREE_LINKS: JSON.stringify(treeLinks),
      N2DD_FAKE_TREE_IMAGE_COUNTS: JSON.stringify({ [title]: 0, 子页面: 1, 孙页面: 1 }),
    },
  });
  assert.equal(first.status, 0, first.stderr);
  assert.equal(first.data.success, true);
  assert.equal(first.data.mode, "tree");
  assert.equal(first.data.checks.recursivePageCount, 3);
  assert.equal(first.data.checks.recursiveFolderCount, 3);
  assert.equal(first.data.checks.recursiveLinkCount, 2);
  assert.equal(first.data.checks.recursiveLinksMatch, true);
  assert.equal(first.data.checks.expectedImageCount, 2);
  assert.equal(first.data.checks.readbackImageCount, 2);
  assert.equal(first.data.local.docx.count, 3);
  assert.equal(first.data.local.docx.permanentlyDeleted, true);
  assert.equal(first.data.cleanup.verified, true);
  assert.match(first.data.remote.documentUrl, /fake-tree-node-1$/u);
  assertMinimalState(first);

  const folderCalls = first.calls.filter((call) =>
    call.args?.[0] === "drive" && call.args?.[1] === "mkdir"
  );
  assert.equal(folderCalls.length, 3);
  assert.equal(folderCalls[0].args[folderCalls[0].args.indexOf("--folder") + 1], "fake-stage3-folder");
  assert.equal(folderCalls[1].args[folderCalls[1].args.indexOf("--folder") + 1], "fake-tree-folder-1");
  assert.equal(folderCalls[2].args[folderCalls[2].args.indexOf("--folder") + 1], "fake-tree-folder-2");

  const imports = first.calls.filter((call) =>
    call.args?.[0] === "doc" && call.args?.[1] === "+import"
  );
  assert.equal(imports.length, 3);
  assert.deepEqual(
    imports.map((call) => call.args[call.args.indexOf("--folder") + 1]),
    ["fake-tree-folder-1", "fake-tree-folder-2", "fake-tree-folder-3"],
  );
  const linkUpdates = first.calls.filter((call) => {
    const element = call.args?.[call.args.indexOf("--element") + 1] ?? "";
    return call.args?.[0] === "doc" && call.args?.[1] === "block" &&
      call.args?.[2] === "update" && element.includes("https://alidocs.dingtalk.com/i/nodes/fake-tree-node-");
  });
  assert.equal(linkUpdates.length, 2);
  const updatedElements = linkUpdates.map((call) =>
    call.args[call.args.indexOf("--element") + 1]
  );
  assert.ok(updatedElements[0].includes("https://alidocs.dingtalk.com/i/nodes/fake-tree-node-2"));
  assert.ok(updatedElements[1].includes("https://alidocs.dingtalk.com/i/nodes/fake-tree-node-3"));

  const repeated = runMigration("recursive-tree", subpageFixture, 0, {
    title,
    subpages: "tree",
    defaultOutput: true,
    env: {
      N2DD_FAKE_TREE_LINKS: JSON.stringify(treeLinks),
      N2DD_FAKE_TREE_IMAGE_COUNTS: JSON.stringify({ [title]: 0, 子页面: 1, 孙页面: 1 }),
    },
  });
  assert.equal(repeated.status, 0, repeated.stderr);
  assert.equal(repeated.data.reused, true);
  assert.equal(repeated.calls.length, 0, "相同递归任务不应再次创建文件夹或文档");
});

test("文件夹目标属于 Workspace 时解析真实 workspaceId 并用 Wiki 接口递归", () => {
  const title = "Workspace 文件夹递归自动验收-" + runNonce;
  const result = runMigration("recursive-workspace-folder-tree", longFixture, 0, {
    title,
    subpages: "tree",
    defaultOutput: true,
    env: {
      N2DD_FAKE_FOLDER_WORKSPACE_ID: "fake-resolved-workspace",
      N2DD_FAKE_TREE_LINKS: JSON.stringify({ [title]: [] }),
      N2DD_FAKE_TREE_IMAGE_COUNTS: JSON.stringify({ [title]: 0 }),
    },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.data.success, true);
  const targetReads = result.calls.filter((call) =>
    call.args?.[0] === "wiki" && call.args?.[1] === "+node-get"
  );
  assert.equal(targetReads.length, 1);
  assert.ok(targetReads[0].args.includes("fake-stage3-folder"));
  assert.equal(result.calls.some((call) =>
    call.args?.[0] === "drive" && call.args?.[1] === "+inspect"
  ), false, "Workspace 节点解析成功后不应再按钉盘探测");
  const wikiCreates = result.calls.filter((call) =>
    call.args?.[0] === "wiki" && call.args?.[1] === "+node-create"
  );
  assert.equal(wikiCreates.length, 1);
  assert.equal(wikiCreates[0].args[wikiCreates[0].args.indexOf("--workspace") + 1], "fake-resolved-workspace");
  assert.equal(wikiCreates[0].args[wikiCreates[0].args.indexOf("--folder") + 1], "fake-stage3-folder");
  assertMinimalState(result);
});

test("旧版误把 Workspace 文件夹按 Drive 处理的未知状态可安全恢复", () => {
  const title = "旧版 Workspace 路由恢复-" + runNonce;
  const commonEnv = {
    N2DD_FAKE_FOLDER_WORKSPACE_ID: "fake-resolved-workspace",
    N2DD_FAKE_TREE_LINKS: JSON.stringify({ [title]: [] }),
    N2DD_FAKE_TREE_IMAGE_COUNTS: JSON.stringify({ [title]: 0 }),
  };
  const failed = runMigration("legacy-workspace-folder-recovery", longFixture, 0, {
    title,
    subpages: "tree",
    defaultOutput: true,
    env: { ...commonEnv, N2DD_FAKE_WIKI_FOLDER_UNKNOWN: "1" },
  });
  assert.notEqual(failed.status, 0);
  assert.equal(failed.data.error.code, "TREE_FOLDER_CREATE_UNKNOWN");
  const legacyState = JSON.parse(readFileSync(failed.data.stateRecord, "utf8"));
  delete legacyState.target.backend;
  delete legacyState.target.workspaceId;
  writeFileSync(failed.data.stateRecord, JSON.stringify(legacyState, null, 2), "utf8");

  const recovered = runMigration("legacy-workspace-folder-recovery", longFixture, 0, {
    title,
    subpages: "tree",
    defaultOutput: true,
    env: commonEnv,
  });
  assert.equal(recovered.status, 0, recovered.stderr);
  assert.equal(recovered.data.success, true);
  assert.equal(recovered.calls.filter((call) =>
    call.args?.[0] === "wiki" && call.args?.[1] === "+node-create"
  ).length, 1);
  assert.equal(recovered.calls.filter((call) =>
    call.args?.[0] === "wiki" && call.args?.[1] === "+node-list"
  ).length, 1, "恢复前必须完整回读父目录并确认没有同名文件夹");
  assertMinimalState(recovered);
});

test("旧未知状态回读到同名文件夹时继续禁止自动重试", () => {
  const title = "旧状态同名保护-" + runNonce;
  const commonEnv = {
    N2DD_FAKE_FOLDER_WORKSPACE_ID: "fake-resolved-workspace",
    N2DD_FAKE_TREE_LINKS: JSON.stringify({ [title]: [] }),
    N2DD_FAKE_TREE_IMAGE_COUNTS: JSON.stringify({ [title]: 0 }),
  };
  const failed = runMigration("legacy-workspace-folder-conflict", longFixture, 0, {
    title,
    subpages: "tree",
    defaultOutput: true,
    env: { ...commonEnv, N2DD_FAKE_WIKI_FOLDER_UNKNOWN: "1" },
  });
  assert.notEqual(failed.status, 0);
  const legacyState = JSON.parse(readFileSync(failed.data.stateRecord, "utf8"));
  delete legacyState.target.backend;
  delete legacyState.target.workspaceId;
  writeFileSync(failed.data.stateRecord, JSON.stringify(legacyState, null, 2), "utf8");

  const blocked = runMigration("legacy-workspace-folder-conflict", longFixture, 0, {
    title,
    subpages: "tree",
    defaultOutput: true,
    env: { ...commonEnv, N2DD_FAKE_EXISTING_TREE_FOLDER: title },
  });
  assert.notEqual(blocked.status, 0);
  assert.equal(blocked.data.error.code, "PREVIOUS_TREE_FOLDER_UNKNOWN");
  assert.match(blocked.data.error.message, /已经存在同名文件夹/u);
  assert.equal(blocked.calls.some((call) =>
    call.args?.[0] === "wiki" && call.args?.[1] === "+node-create"
  ), false, "存在同名候选时不得再次创建目录");
});

test("递归文档树在知识库目标中使用原生 Wiki 文件夹", () => {
  const title = "知识库递归自动验收-" + runNonce;
  const result = runMigration("recursive-wiki-tree", longFixture, 0, {
    title,
    subpages: "tree",
    workspace: "fake-stage3-wiki",
    defaultOutput: true,
    env: {
      N2DD_FAKE_TREE_LINKS: JSON.stringify({ [title]: [] }),
      N2DD_FAKE_TREE_IMAGE_COUNTS: JSON.stringify({ [title]: 0 }),
    },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.data.checks.recursivePageCount, 1);
  assert.equal(result.data.checks.recursiveFolderCount, 1);
  const wikiCreates = result.calls.filter((call) =>
    call.args?.[0] === "wiki" && call.args?.[1] === "+node-create"
  );
  assert.equal(wikiCreates.length, 1);
  assert.ok(wikiCreates[0].args.includes("--workspace"));
  assert.ok(wikiCreates[0].args.includes("fake-stage3-wiki"));
  assert.ok(wikiCreates[0].args.includes("--type"));
  assert.ok(wikiCreates[0].args.includes("folder"));
  assert.equal(wikiCreates[0].args.includes("--folder"), false, "知识库根页面文件夹应直接建在库根目录");
  const imports = result.calls.filter((call) =>
    call.args?.[0] === "doc" && call.args?.[1] === "+import"
  );
  assert.equal(imports.length, 1);
  assert.ok(imports[0].args.includes("fake-tree-wiki-folder-1"));
});

test("缺失的嵌套子页面在调用钉钉前明确失败", () => {
  const copiedFixture = path.join(runtimeRoot, "missing-subpage-fixture");
  rmSync(copiedFixture, { recursive: true, force: true });
  cpSync(subpageFixture, copiedFixture, { recursive: true });
  const missingPage = path.join(
    copiedFixture,
    "父页面 44444444444444444444444444444444",
    "子页面 55555555555555555555555555555555",
    "孙页面 66666666666666666666666666666666.html",
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
