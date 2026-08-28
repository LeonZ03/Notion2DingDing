import assert from "node:assert/strict";
import { mkdtemp, mkdir, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import test from "node:test";

const root = resolve(import.meta.dirname, "..", "..");
const hostPath = join(root, "dist", "native-host", "notion2dingding-host.exe");
const fakeCLI = join(root, "tests", "stage5", "fake-installed-cli.ps1");
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

function makeZip(title) {
  const name = Buffer.from(`${title}.html`, "utf8");
  const content = Buffer.from(`<!doctype html><title>${title}</title><p>stage6</p>`, "utf8");
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

function request(requestId, method, params) {
  return { protocolVersion: 1, requestId, method, params };
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

class NativeClient {
  constructor(environment) {
    this.child = spawn(hostPath, [], {
      env: { ...process.env, ...environment },
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    this.buffer = Buffer.alloc(0);
    this.pending = new Map();
    this.stderr = [];
    this.child.stderr.on("data", (chunk) => this.stderr.push(chunk));
    this.child.stdout.on("data", (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      while (this.buffer.length >= 4) {
        const length = this.buffer.readUInt32LE(0);
        if (this.buffer.length < length + 4) break;
        const response = JSON.parse(this.buffer.subarray(4, length + 4).toString("utf8"));
        this.buffer = this.buffer.subarray(length + 4);
        const waiter = this.pending.get(response.requestId);
        if (waiter) {
          this.pending.delete(response.requestId);
          waiter.resolve(response);
        }
      }
    });
    this.child.once("error", (error) => {
      for (const waiter of this.pending.values()) waiter.reject(error);
      this.pending.clear();
    });
  }

  send(value) {
    return new Promise((resolve, reject) => {
      this.pending.set(value.requestId, { resolve, reject });
      this.child.stdin.write(frame(value), (error) => {
        if (error) {
          this.pending.delete(value.requestId);
          reject(error);
        }
      });
    });
  }

  async close() {
    this.child.stdin.end();
    const exitCode = await new Promise((resolve, reject) => {
      this.child.once("error", reject);
      this.child.once("exit", resolve);
    });
    assert.equal(exitCode, 0, Buffer.concat(this.stderr).toString("utf8"));
    assert.equal(this.pending.size, 0);
  }
}

async function waitForTerminal(client, taskId, prefix, observations) {
  for (let index = 0; index < 120; index += 1) {
    const response = await client.send(request(`${prefix}-${index}`, "migration.status", { taskId }));
    assert.equal(response.ok, true, JSON.stringify(response));
    observations.push(response.result);
    if (!["queued", "running", "cancel_requested"].includes(response.result.status)) {
      return response.result;
    }
    await delay(50);
  }
  throw new Error(`task ${taskId} did not reach a terminal state`);
}

test("persistent Native Host reports progress, cancellation and cleanup", async () => {
  const temporaryRoot = await mkdtemp(join(tmpdir(), "notion2dingding-stage6-"));
  const dataDirectory = join(temporaryRoot, "data");
  await mkdir(dataDirectory, { recursive: true });
  await writeFile(join(dataDirectory, "config.json"), JSON.stringify({ folder: "folder-test" }));
  const client = new NativeClient({
    N2DD_HOST_CLI_SCRIPT: fakeCLI,
    N2DD_HOST_DATA_DIRECTORY: dataDirectory,
    N2DD_HOST_POWERSHELL: powershell,
    N2DD_FAKE_STAGE6_DELAY: "1",
  });

  try {
    const started = await client.send(request("start-success", "migration.start", {
      fileName: "slow-success.zip",
      contentBase64: makeZip("slow-success").toString("base64"),
      title: "slow-success",
      subpageMode: "inline",
      createNew: true,
    }));
    assert.equal(started.ok, true, JSON.stringify(started));
    assert.match(started.result.taskId, /^[0-9a-f]{16}$/u);
    assert.ok(["queued", "running"].includes(started.result.status));

    const observations = [started.result];
    const completed = await waitForTerminal(client, started.result.taskId, "success-status", observations);
    assert.equal(completed.status, "succeeded");
    assert.equal(completed.progress.percent, 100);
    assert.equal(completed.result.cleanupVerified, true);
    assert.match(completed.result.documentUrl, /^https:\/\/alidocs\.dingtalk\.com\//u);
    assert.ok(observations.some((item) => item.status === "running"));
    assert.ok(observations.some((item) => item.progress.stage === "convert" || item.progress.stage === "import"));

    const cancelStarted = await client.send(request("start-cancel", "migration.start", {
      fileName: "cancel.zip",
      contentBase64: makeZip("cancel-me").toString("base64"),
      title: "cancel-me",
    }));
    assert.equal(cancelStarted.ok, true, JSON.stringify(cancelStarted));
    await delay(200);
    const cancelRequested = await client.send(request("cancel", "migration.cancel", {
      taskId: cancelStarted.result.taskId,
    }));
    assert.equal(cancelRequested.ok, true);
    assert.ok(["cancel_requested", "cancelled"].includes(cancelRequested.result.status));
    const cancelled = await waitForTerminal(client, cancelStarted.result.taskId, "cancel-status", []);
    assert.equal(cancelled.status, "cancelled");
    assert.equal(cancelled.error.code, "migration_cancelled");

    const taskEntries = await readdir(join(dataDirectory, "native-host", "tasks"));
    assert.deepEqual(taskEntries, [], "stage 6 success and cancel paths must remove staged exports");
  } finally {
    await client.close();
    await rm(temporaryRoot, { recursive: true, force: true });
  }
});
