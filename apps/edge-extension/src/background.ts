import {
  createRequest,
  isNativeResponse,
  NATIVE_HOST_NAME,
  type HealthResult,
  type NativeResponse,
} from "./protocol.js";

interface ExtensionMessage {
  type: "native.health";
}

interface ExtensionReply {
  ok: boolean;
  response?: NativeResponse<HealthResult>;
  error?: string;
}

chrome.runtime.onMessage.addListener(
  (
    message: ExtensionMessage,
    _sender: chrome.runtime.MessageSender,
    sendResponse: (reply: ExtensionReply) => void,
  ) => {
    if (message?.type !== "native.health") {
      return false;
    }

    const request = createRequest("health.check", {});
    chrome.runtime.sendNativeMessage(NATIVE_HOST_NAME, request, (value) => {
      const runtimeError = chrome.runtime.lastError;
      if (runtimeError) {
        sendResponse({
          ok: false,
          error: runtimeError.message ?? "无法连接本地助手。",
        });
        return;
      }

      if (!isNativeResponse(value)) {
        sendResponse({ ok: false, error: "本地助手返回了无效响应。" });
        return;
      }

      const reply: ExtensionReply = {
        ok: value.ok,
        response: value as NativeResponse<HealthResult>,
      };
      if (value.error?.message) {
        reply.error = value.error.message;
      }
      sendResponse(reply);
    });

    return true;
  },
);
