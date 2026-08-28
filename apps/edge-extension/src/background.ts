import {
  createRequest,
  isNativeResponse,
  NATIVE_HOST_NAME,
  type HealthResult,
  type LocalOpenParams,
  type LocalOpenResult,
  type MigrationExportParams,
  type MigrationExportInspection,
  type MigrationTaskParams,
  type MigrationTaskSnapshot,
  type NativeResponse,
} from "./protocol.js";

type ExtensionMessage =
  | { type: "native.health" }
  | { type: "native.open"; params: LocalOpenParams }
  | { type: "native.export.transfer.begin"; params: ExportTransferBeginParams }
  | { type: "native.export.transfer.chunk"; params: ExportTransferChunkParams }
  | { type: "native.export.transfer.abort"; params: { transferId: string } }
  | { type: "native.export.transfer.commit"; params: ExportTransferCommitParams }
  | { type: "native.task.status"; params: MigrationTaskParams }
  | { type: "native.task.cancel"; params: MigrationTaskParams };

interface ExportTransferBeginParams {
  transferId: string;
  fileName: string;
  rawBytes: number;
  encodedCharacters: number;
  totalChunks: number;
}

interface ExportTransferChunkParams {
  transferId: string;
  index: number;
  contentBase64: string;
}

interface ExportTransferCommitParams {
  transferId: string;
  operation: "inspect" | "start";
  migration?: Omit<MigrationExportParams, "fileName" | "contentBase64">;
}

interface ExportTransfer {
  fileName: string;
  rawBytes: number;
  encodedCharacters: number;
  totalChunks: number;
  chunks: string[];
  receivedCharacters: number;
  updatedAt: number;
}

export interface ExtensionReply<TResult = unknown> {
  ok: boolean;
  response?: NativeResponse<TResult>;
  error?: string;
}

interface PendingNativeRequest {
  resolve: (reply: ExtensionReply<unknown>) => void;
}

let nativePort: chrome.runtime.Port | undefined;
const pending = new Map<string, PendingNativeRequest>();
const exportTransfers = new Map<string, ExportTransfer>();
const maxTransferCharacters = 63 * 1024 * 1024;
const maxTransferChunkCharacters = 768 * 1024;
const transferLifetimeMilliseconds = 5 * 60 * 1000;

function validTransferId(value: string): boolean {
  return /^[0-9a-f-]{16,64}$/iu.test(value);
}

function pruneExportTransfers(): void {
  const cutoff = Date.now() - transferLifetimeMilliseconds;
  for (const [transferId, transfer] of exportTransfers) {
    if (transfer.updatedAt < cutoff) exportTransfers.delete(transferId);
  }
}

function transferFailure(error: string): ExtensionReply<never> {
  return { ok: false, error };
}

function beginExportTransfer(params: ExportTransferBeginParams): ExtensionReply<never> {
  pruneExportTransfers();
  if (
    !validTransferId(params.transferId) ||
    params.fileName.length < 1 ||
    params.fileName.length > 500 ||
    !params.fileName.toLowerCase().endsWith(".zip") ||
    params.rawBytes < 1 ||
    params.encodedCharacters < 1 ||
    Math.ceil(params.rawBytes / 3) * 4 !== params.encodedCharacters ||
    params.encodedCharacters > maxTransferCharacters ||
    params.totalChunks < 1 ||
    params.totalChunks > 256
  ) {
    return transferFailure("导出包分片参数无效，请重新选择 ZIP。");
  }
  exportTransfers.set(params.transferId, {
    fileName: params.fileName,
    rawBytes: params.rawBytes,
    encodedCharacters: params.encodedCharacters,
    totalChunks: params.totalChunks,
    chunks: [],
    receivedCharacters: 0,
    updatedAt: Date.now(),
  });
  return { ok: true };
}

function appendExportTransfer(params: ExportTransferChunkParams): ExtensionReply<never> {
  const transfer = exportTransfers.get(params.transferId);
  if (!transfer) return transferFailure("导出包分片会话已失效，请重新选择 ZIP。");
  if (
    params.index !== transfer.chunks.length ||
    params.index >= transfer.totalChunks ||
    params.contentBase64.length < 1 ||
    params.contentBase64.length > maxTransferChunkCharacters ||
    transfer.receivedCharacters + params.contentBase64.length > transfer.encodedCharacters
  ) {
    exportTransfers.delete(params.transferId);
    return transferFailure("导出包分片顺序或大小无效，请重新选择 ZIP。");
  }
  transfer.chunks.push(params.contentBase64);
  transfer.receivedCharacters += params.contentBase64.length;
  transfer.updatedAt = Date.now();
  return { ok: true };
}

function takeExportTransfer(transferId: string): ExportTransfer | undefined {
  const transfer = exportTransfers.get(transferId);
  exportTransfers.delete(transferId);
  if (!transfer || transfer.chunks.length !== transfer.totalChunks) return undefined;
  if (transfer.receivedCharacters !== transfer.encodedCharacters) return undefined;
  const contentBase64 = transfer.chunks.join("");
  const padding = contentBase64.endsWith("==") ? 2 : contentBase64.endsWith("=") ? 1 : 0;
  const decodedBytes = (contentBase64.length / 4) * 3 - padding;
  return decodedBytes === transfer.rawBytes ? transfer : undefined;
}

function disconnectReason(): string {
  return chrome.runtime.lastError?.message ?? "Native Host 已断开，请重新打开扩展后重试。";
}

function rejectPending(message: string): void {
  for (const request of pending.values()) {
    request.resolve({ ok: false, error: message });
  }
  pending.clear();
}

function connectNative(): chrome.runtime.Port {
  if (nativePort) {
    return nativePort;
  }
  const port = chrome.runtime.connectNative(NATIVE_HOST_NAME);
  nativePort = port;
  port.onMessage.addListener((value: unknown) => {
    if (!isNativeResponse(value)) {
      rejectPending("本地助手返回了无效响应。");
      return;
    }
    const request = pending.get(value.requestId);
    if (!request) {
      return;
    }
    pending.delete(value.requestId);
    const response = value as NativeResponse<unknown>;
    if (response.ok) {
      request.resolve({ ok: true, response });
    } else {
      request.resolve({
        ok: false,
        response,
        error: response.error?.message ?? "本地助手未返回具体错误。",
      });
    }
  });
  port.onDisconnect.addListener(() => {
    const message = disconnectReason();
    if (nativePort === port) {
      nativePort = undefined;
    }
    rejectPending(message);
  });
  return port;
}

function sendNative<TResult>(method: string, params: unknown): Promise<ExtensionReply<TResult>> {
  const request = createRequest(method, params);
  return new Promise((resolve) => {
    const port = connectNative();
    pending.set(request.requestId, {
      resolve: resolve as (reply: ExtensionReply<unknown>) => void,
    });
    try {
      port.postMessage(request);
    } catch (error) {
      pending.delete(request.requestId);
      if (nativePort === port) {
        nativePort = undefined;
      }
      resolve({
        ok: false,
        error: error instanceof Error ? error.message : "无法连接本地助手。",
      });
    }
  });
}

chrome.runtime.onMessage.addListener(
  (
    message: ExtensionMessage,
    _sender: chrome.runtime.MessageSender,
    sendResponse: (reply: ExtensionReply<unknown>) => void,
  ) => {
    if (message?.type === "native.health") {
      void sendNative<HealthResult>("health.check", {}).then(sendResponse);
      return true;
    }
    if (message?.type === "native.open") {
      void sendNative<LocalOpenResult>("local.open", message.params).then(sendResponse);
      return true;
    }
    if (message?.type === "native.export.transfer.begin") {
      sendResponse(beginExportTransfer(message.params));
      return true;
    }
    if (message?.type === "native.export.transfer.chunk") {
      sendResponse(appendExportTransfer(message.params));
      return true;
    }
    if (message?.type === "native.export.transfer.abort") {
      exportTransfers.delete(message.params.transferId);
      sendResponse({ ok: true });
      return true;
    }
    if (message?.type === "native.export.transfer.commit") {
      const transfer = takeExportTransfer(message.params.transferId);
      if (!transfer) {
        sendResponse(transferFailure("导出包分片不完整，请重新选择 ZIP。"));
        return true;
      }
      const params: MigrationExportParams = {
        ...(message.params.migration ?? {}),
        fileName: transfer.fileName,
        contentBase64: transfer.chunks.join(""),
      };
      if (message.params.operation === "inspect") {
        void sendNative<MigrationExportInspection>("migration.inspect", params).then(sendResponse);
      } else {
        void sendNative<MigrationTaskSnapshot>("migration.start", params).then(sendResponse);
      }
      return true;
    }
    if (message?.type === "native.task.status") {
      void sendNative<MigrationTaskSnapshot>("migration.status", message.params).then(sendResponse);
      return true;
    }
    if (message?.type === "native.task.cancel") {
      void sendNative<MigrationTaskSnapshot>("migration.cancel", message.params).then(sendResponse);
      return true;
    }
    return false;
  },
);
