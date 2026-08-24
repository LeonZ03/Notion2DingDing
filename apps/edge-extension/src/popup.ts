interface HealthReply {
  ok: boolean;
  response?: {
    result?: {
      hostVersion: string;
      platform: string;
      capabilities: string[];
    };
  };
  error?: string;
}

const statusElement = document.querySelector<HTMLDivElement>("#status");
const checkButton = document.querySelector<HTMLButtonElement>("#check-host");

function setStatus(message: string, kind: "idle" | "success" | "error"): void {
  if (!statusElement) {
    return;
  }

  statusElement.textContent = message;
  statusElement.dataset.kind = kind;
}

function checkNativeHost(): void {
  if (!checkButton) {
    return;
  }

  checkButton.disabled = true;
  setStatus("正在检查本地助手…", "idle");

  chrome.runtime.sendMessage({ type: "native.health" }, (reply?: HealthReply) => {
    checkButton.disabled = false;

    const runtimeError = chrome.runtime.lastError;
    if (runtimeError) {
      setStatus(runtimeError.message ?? "扩展内部通信失败。", "error");
      return;
    }

    const health = reply?.response?.result;
    if (!reply?.ok || !health) {
      setStatus(reply?.error ?? "尚未连接本地助手。", "error");
      return;
    }

    setStatus(
      `本地助手 ${health.hostVersion} 已连接（${health.platform}）`,
      "success",
    );
  });
}

checkButton?.addEventListener("click", checkNativeHost);
checkNativeHost();
