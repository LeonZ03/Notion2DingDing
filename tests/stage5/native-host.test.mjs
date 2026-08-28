import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import test from "node:test";

const repositoryRoot = resolve(import.meta.dirname, "..", "..");
const hostPath = join(repositoryRoot, "dist", "native-host", "notion2dingding-host.exe");
const fakeCLI = join(repositoryRoot, "tests", "stage5", "fake-installed-cli.ps1");
const powershell = join(
  process.env.SystemRoot ?? "C:\\Windows",
  "System32",
  "WindowsPowerShell",
  "v1.0",
  "powershell.exe",
);

function crc32(buffer) {
  let value = 0xffffffff;
  for (const byte of buffer) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value >>> 1) ^ (0xedb88320 & -(value & 1));
    }
  }
  return (value ^ 0xffffffff) >>> 0;
}

function makeZip(fileName, text) {
  const name = Buffer.from(fileName, "utf8");
  const content = Buffer.from(text, "utf8");
  const checksum = crc32(content);
  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4);
  local.writeUInt32LE(checksum, 14);
  local.writeUInt32LE(content.length, 18);
  local.writeUInt32LE(content.length, 22);
  local.writeUInt16LE(name.length, 26);
  const central = Buffer.alloc(46);
  central.writeUInt32LE(0x02014b50, 0);
  central.writeUInt16LE(20, 4);
  central.writeUInt16LE(20, 6);
  central.writeUInt32LE(checksum, 16);
  central.writeUInt32LE(content.length, 20);
  central.writeUInt32LE(content.length, 24);
  central.writeUInt16LE(name.length, 28);
  const centralOffset = local.length + name.length + content.length;
  const centralSize = central.length + name.length;
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(1, 8);
  end.writeUInt16LE(1, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(centralOffset, 16);
  return Buffer.concat([local, name, content, central, name, end]);
}

function frame(value) {
  const payload = Buffer.from(JSON.stringify(value), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(payload.length);
  return Buffer.concat([header, payload]);
}

async function invokeHost(request, environment) {
  const child = spawn(hostPath, [], {
    env: { ...process.env, ...environment },
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  const stdout = [];
  const stderr = [];
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.push(chunk));
  child.stdin.end(frame(request));
  const exitCode = await new Promise((accept, reject) => {
    child.once("error", reject);
    child.once("exit", accept);
  });
  const output = Buffer.concat(stdout);
  assert.equal(exitCode, 0, Buffer.concat(stderr).toString("utf8"));
  assert.ok(output.length >= 4, "native host must return one framed response");
  const responseLength = output.readUInt32LE(0);
  assert.equal(output.length, responseLength + 4, "stdout must contain only one native frame");
  return JSON.parse(output.subarray(4).toString("utf8"));
}

async function invokeInstalledCLI(arguments_, environment, cwd) {
  const child = spawn(
    powershell,
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", fakeCLI, ...arguments_],
    { env: { ...process.env, ...environment }, cwd, stdio: ["ignore", "pipe", "pipe"], windowsHide: true },
  );
  const stdout = [];
  const stderr = [];
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.push(chunk));
  const exitCode = await new Promise((accept, reject) => {
    child.once("error", reject);
    child.once("exit", accept);
  });
  assert.equal(exitCode, 0, Buffer.concat(stderr).toString("utf8"));
  return JSON.parse(Buffer.concat(stdout).toString("utf8"));
}

function request(requestId, method, params = {}) {
  return { protocolVersion: 1, requestId, method, params };
}

test("Native Host reuses the installed core for health and export migrations", async () => {
  const temporaryRoot = await mkdtemp(join(tmpdir(), "notion2dingding-stage5-"));
  const dataDirectory = join(temporaryRoot, "data");
  const logPath = join(temporaryRoot, "fake-cli.jsonl");
  await mkdir(dataDirectory, { recursive: true });
  await writeFile(
    join(dataDirectory, "config.json"),
    JSON.stringify({ folder: "folder-test", folderName: "我的文件 / 验证输出" }),
  );
  const environment = {
    N2DD_HOST_CLI_SCRIPT: fakeCLI,
    N2DD_HOST_DATA_DIRECTORY: dataDirectory,
    N2DD_HOST_POWERSHELL: powershell,
    N2DD_FAKE_LOG: logPath,
  };

  try {
    const firstHealth = await invokeHost(request("health-1", "health.check"), environment);
    assert.equal(firstHealth.ok, true);
    assert.equal(firstHealth.result.localTool.ready, true);
    assert.equal(firstHealth.result.localTool.authenticated, true);
    assert.equal(firstHealth.result.localTool.configured, true);
    assert.equal(firstHealth.result.localTool.targetType, "folder");
    assert.equal(firstHealth.result.localTool.targetDisplayName, "我的文件 / 验证输出");
    assert.deepEqual(firstHealth.result.capabilities, [
      "health.check",
      "local.open",
      "migration.inspect",
      "migration.export",
      "migration.start",
      "migration.status",
      "migration.cancel",
    ]);

    const restartedHealth = await invokeHost(request("health-2", "health.check"), environment);
    assert.equal(restartedHealth.ok, true, "a freshly restarted host must remain usable");

    const inspectionZip = makeZip("包内标题.html", "<!doctype html><title>包内标题</title><p>inspect</p>");
    const inspection = await invokeHost(
      request("inspect-export", "migration.inspect", {
        fileName: "selected-export.zip",
        contentBase64: inspectionZip.toString("base64"),
      }),
      environment,
    );
    assert.equal(inspection.ok, true, JSON.stringify(inspection));
    assert.equal(inspection.result.fileName, "selected-export.zip");
    assert.equal(inspection.result.title, "导出包识别标题");
    assert.equal(inspection.result.exportedAt, "2026-08-28T02:00:00.0000000Z");
    assert.equal(inspection.result.pageCount, 3);
    assert.equal(inspection.result.bytes, inspectionZip.length);
    await assert.rejects(
      import("node:fs/promises").then(({ readdir }) => readdir(join(dataDirectory, "native-host", "inspections"))),
      { code: "ENOENT" },
      "inspection copies must be permanently removed before responding",
    );

    const fixtures = [
      ["ordinary", 1, 3, "inline"],
      ["long-page", 2, 0, "inline"],
      ["multi-image", 8, 0, "inline"],
      ["recursive-tree", 1, 0, "tree"],
    ];
    const sourceHashes = new Map();
    let ordinaryHostResult;
    for (const [name, images, todos, subpageMode] of fixtures) {
      const zip = makeZip(`${name}.html`, `<!doctype html><title>${name}</title><p>fixture:${name}</p>`);
      sourceHashes.set(name, createHash("sha256").update(zip).digest("hex"));
      const response = await invokeHost(
        request(`migrate-${name}`, "migration.export", {
          fileName: `${name}.zip`,
          contentBase64: zip.toString("base64"),
          title: name,
          subpageMode,
          createNew: name === "ordinary",
          sourcePage: {
            url: "https://www.notion.so/example",
            title: name,
            visibleTextBytes: 16,
            visibleBlockCount: 2,
            visibleImageCount: images,
            exportRequired: true,
          },
        }),
        environment,
      );
      assert.equal(response.ok, true, JSON.stringify(response));
      assert.equal(response.result.expectedImageCount, images);
      assert.equal(response.result.readbackImageCount, images);
      assert.equal(response.result.nativeTodoCount, todos);
      assert.equal(response.result.nativeCodeBlockCount, name === "ordinary" ? 2 : 0);
      assert.equal(response.result.nativeSubpageTocItemCount, name === "ordinary" ? 2 : 0);
      assert.equal(response.result.subpageMode, subpageMode);
      assert.equal(response.result.recursivePageCount ?? 0, subpageMode === "tree" ? 3 : 0);
      assert.equal(response.result.recursiveFolderCount ?? 0, subpageMode === "tree" ? 3 : 0);
      assert.equal(response.result.recursiveLinkCount ?? 0, subpageMode === "tree" ? 2 : 0);
      assert.equal(response.result.cleanupVerified, true);
      assert.equal(response.result.sourcePageCaptured, true);
      if (name === "ordinary") {
        ordinaryHostResult = response.result;
      }
    }

    const invalidPath = await invokeHost(
      request("bad-path", "migration.export", {
        fileName: "../escape.zip",
        contentBase64: "UEsDBA==",
      }),
      environment,
    );
    assert.equal(invalidPath.ok, false);
    assert.equal(invalidPath.error.code, "invalid_export");

    const invalidFile = await invokeHost(
      request("bad-file", "migration.export", {
        fileName: "bad.zip",
        contentBase64: Buffer.from("not a zip").toString("base64"),
      }),
      environment,
    );
    assert.equal(invalidFile.ok, false);
    assert.equal(invalidFile.error.code, "invalid_export");

    const tasksRoot = join(dataDirectory, "native-host", "tasks");
    const { readdir } = await import("node:fs/promises");
    const taskEntries = await readdir(tasksRoot);
    assert.deepEqual(taskEntries, [], "Native Host staging copies must be permanently removed");

    const directZip = makeZip("ordinary.html", "<!doctype html><title>ordinary</title><p>fixture:ordinary</p>");
    const directPath = join(temporaryRoot, "direct.zip");
    await writeFile(directPath, directZip);
    assert.equal(basename(directPath), "direct.zip");
    assert.equal(createHash("sha256").update(directZip).digest("hex"), sourceHashes.get("ordinary"));
    const directResult = await invokeInstalledCLI(
      ["migrate", "--input", directPath, "--name", "ordinary"],
      environment,
      dataDirectory,
    );
    assert.equal(directResult.taskId, ordinaryHostResult.taskId);
    assert.equal(directResult.remote.documentUrl, ordinaryHostResult.documentUrl);
    assert.equal(directResult.checks.expectedImageCount, ordinaryHostResult.expectedImageCount);
    assert.equal(directResult.checks.nativeTodoCount, ordinaryHostResult.nativeTodoCount);
    assert.equal(directResult.checks.nativeCodeBlockCount, ordinaryHostResult.nativeCodeBlockCount);
    assert.equal(
      directResult.checks.nativeSubpageTocItemCount,
      ordinaryHostResult.nativeSubpageTocItemCount,
    );

    const logLines = (await readFile(logPath, "utf8")).trim().split(/\r?\n/u).map(JSON.parse);
    assert.equal(logLines.length, 5);
    for (const line of logLines) {
      assert.equal(line.sha256, sourceHashes.get(line.title), "host and CLI must preserve exact source bytes");
    }
    assert.equal(logLines.filter((line) => line.inputName === "source.zip").length, 4);
    assert.equal(logLines.filter((line) => line.inputName === "direct.zip").length, 1);
    assert.equal(logLines.find((line) => line.title === "ordinary" && line.inputName === "source.zip")?.createNew, true);
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
});
