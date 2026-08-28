import assert from "node:assert/strict";
import test from "node:test";

let listener;
let nativeConnections = 0;
const nativeCalls = [];
const nativeMessageListeners = [];
const nativeDisconnectListeners = [];

function taskSnapshot(status = "running") {
  return {
    taskId: "0123456789abcdef",
    status,
    progress: {
      current: status === "succeeded" ? 5 : 2,
      total: 5,
      percent: status === "succeeded" ? 100 : 36,
      stage: status === "succeeded" ? "succeeded" : "convert",
      message: status === "succeeded" ? "done" : "converting",
    },
    canCancel: status === "running",
    updatedAt: "2026-08-27T00:00:00Z",
    ...(status === "succeeded"
      ? {
          result: {
            taskId: "task-1",
            documentUrl: "https://alidocs.dingtalk.com/i/nodes/test",
            reused: true,
            expectedImageCount: 2,
            readbackImageCount: 2,
            nativeTodoCount: 1,
            nativeCodeBlockCount: 2,
            nativeSubpageTocItemCount: 2,
            cleanupVerified: true,
            sourcePageCaptured: true,
          },
        }
      : {}),
  };
}

function resultFor(request) {
  if (request.method === "health.check") {
    return {
      hostVersion: "0.3.0",
      protocolVersion: 1,
      platform: "windows/amd64",
      capabilities: [
        "health.check",
        "local.open",
        "migration.inspect",
        "migration.export",
        "migration.start",
        "migration.status",
        "migration.cancel",
      ],
      localTool: {
        installed: true,
        ready: true,
        authenticated: true,
        configured: true,
        targetType: "folder",
        targetDisplayName: "我的文件 / 验证输出",
        message: "ready",
      },
    };
  }
  if (request.method === "local.open") {
    return { started: true, action: request.params.action, message: "opened" };
  }
  if (request.method === "migration.inspect") {
    return {
      fileName: request.params.fileName,
      title: "导出包标题",
      exportedAt: "2026-08-28T02:00:00Z",
      pageCount: 2,
      bytes: 1024,
    };
  }
  if (request.method === "migration.status") return taskSnapshot("succeeded");
  if (request.method === "migration.cancel") return taskSnapshot("cancel_requested");
  return taskSnapshot("running");
}

globalThis.chrome = {
  runtime: {
    lastError: undefined,
    onMessage: {
      addListener(value) {
        listener = value;
      },
    },
    connectNative(hostName) {
      nativeConnections += 1;
      assert.equal(hostName, "com.leonz03.notion2dingding");
      return {
        onMessage: {
          addListener(value) {
            nativeMessageListeners.push(value);
          },
        },
        onDisconnect: {
          addListener(value) {
            nativeDisconnectListeners.push(value);
          },
        },
        postMessage(request) {
          nativeCalls.push({ hostName, request });
          queueMicrotask(() => {
            for (const receive of nativeMessageListeners) {
              receive({
                protocolVersion: 1,
                requestId: request.requestId,
                ok: true,
                result: resultFor(request),
              });
            }
          });
        },
      };
    },
  },
};

await import("../../dist/edge-extension/background.js");

function dispatch(message) {
  return new Promise((resolve, reject) => {
    const keepAlive = listener(message, {}, resolve);
    if (keepAlive !== true) {
      reject(new Error("background did not keep the response channel alive"));
    }
  });
}

async function dispatchExportTransfer(transferId, operation, contentBase64, migration) {
  const chunks = [contentBase64.slice(0, 4), contentBase64.slice(4)];
  const rawBytes = Buffer.from(contentBase64, "base64").length;
  const begun = await dispatch({
    type: "native.export.transfer.begin",
    params: {
      transferId,
      fileName: "export.zip",
      rawBytes,
      encodedCharacters: contentBase64.length,
      totalChunks: chunks.length,
    },
  });
  assert.equal(begun.ok, true);
  for (const [index, content] of chunks.entries()) {
    const appended = await dispatch({
      type: "native.export.transfer.chunk",
      params: { transferId, index, contentBase64: content },
    });
    assert.equal(appended.ok, true);
  }
  return dispatch({
    type: "native.export.transfer.commit",
    params: { transferId, operation, migration },
  });
}

test("background keeps one Native Messaging port for health, setup and async tasks", async () => {
  const health = await dispatch({ type: "native.health" });
  assert.equal(health.ok, true);
  assert.equal(health.response.result.localTool.ready, true);
  assert.equal(nativeCalls[0].request.method, "health.check");

  const opened = await dispatch({ type: "native.open", params: { action: "target" } });
  assert.equal(opened.ok, true);
  assert.equal(opened.response.result.action, "target");
  assert.equal(nativeCalls[1].request.method, "local.open");

  const contentBase64 = "UEsDBA==";
  const inspected = await dispatchExportTransfer("aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa", "inspect", contentBase64);
  assert.equal(inspected.ok, true);
  assert.equal(inspected.response.result.title, "导出包标题");
  assert.equal(nativeCalls[2].request.method, "migration.inspect");
  assert.equal(nativeCalls[2].request.params.contentBase64, contentBase64);

  const migration = { subpageMode: "tree", createNew: true };
  const started = await dispatchExportTransfer(
    "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb",
    "start",
    contentBase64,
    migration,
  );
  assert.equal(started.ok, true);
  assert.equal(started.response.result.status, "running");
  assert.equal(nativeCalls[3].request.method, "migration.start");
  assert.deepEqual(nativeCalls[3].request.params, {
    fileName: "export.zip",
    contentBase64,
    ...migration,
  });

  const status = await dispatch({
    type: "native.task.status",
    params: { taskId: "0123456789abcdef" },
  });
  assert.equal(status.response.result.status, "succeeded");
  assert.equal(nativeCalls[4].request.method, "migration.status");

  const cancelled = await dispatch({
    type: "native.task.cancel",
    params: { taskId: "0123456789abcdef" },
  });
  assert.equal(cancelled.response.result.status, "cancel_requested");
  assert.equal(nativeCalls[5].request.method, "migration.cancel");
  assert.equal(nativeConnections, 1, "all requests must reuse one persistent native port");
  assert.equal(nativeDisconnectListeners.length, 1);
});

test("background ignores unrelated extension messages", () => {
  assert.equal(listener({ type: "unrelated" }, {}, () => {}), false);
});

test("background rejects incomplete or malformed export transfers before Native Messaging", async () => {
  const before = nativeCalls.length;
  const invalid = await dispatch({
    type: "native.export.transfer.begin",
    params: {
      transferId: "cccccccc-cccc-4ccc-cccc-cccccccccccc",
      fileName: "export.zip",
      rawBytes: 4,
      encodedCharacters: 7,
      totalChunks: 1,
    },
  });
  assert.equal(invalid.ok, false);

  const begun = await dispatch({
    type: "native.export.transfer.begin",
    params: {
      transferId: "dddddddd-dddd-4ddd-dddd-dddddddddddd",
      fileName: "export.zip",
      rawBytes: 4,
      encodedCharacters: 8,
      totalChunks: 2,
    },
  });
  assert.equal(begun.ok, true);
  const incomplete = await dispatch({
    type: "native.export.transfer.commit",
    params: {
      transferId: "dddddddd-dddd-4ddd-dddd-dddddddddddd",
      operation: "inspect",
    },
  });
  assert.equal(incomplete.ok, false);
  assert.equal(nativeCalls.length, before);
});
