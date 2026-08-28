import type {
  HealthResult,
  LocalOpenResult,
  MigrationExportParams,
  MigrationExportInspection,
  MigrationResult,
  MigrationTaskSnapshot,
  NativeResponse,
  PageSnapshot,
} from "./protocol.js";
import {
  getNotionPageIdentity,
  isSupportedNotionURL,
  requiresOfficialHTMLExport,
  taskBelongsToCurrentPage,
} from "./page-policy.js";
import {
  evaluateCompatibility,
  INSTALLER_URL,
  RELEASES_URL,
} from "./compatibility.js";

interface ExtensionReply<TResult> {
  ok: boolean;
  response?: NativeResponse<TResult>;
  error?: string;
}

interface StoredTaskReference {
  taskId: string;
  sourcePageIdentity: string;
}

interface SelectedExport {
  file: File;
  contentBase64: string;
  inspection: MigrationExportInspection;
}

const maxExportBytes = 46 * 1024 * 1024;
const exportTransferChunkCharacters = 512 * 1024;
const activeTaskStorageKey = "activeMigrationTaskId";
const activeStatuses = new Set(["queued", "running", "cancel_requested"]);

const hostStatus = document.querySelector<HTMLParagraphElement>("#host-status");
const pageStatus = document.querySelector<HTMLParagraphElement>("#page-status");
const checkButton = document.querySelector<HTMLButtonElement>("#check-host");
const migrateButton = document.querySelector<HTMLButtonElement>("#migrate-export");
const selectExportButton = document.querySelector<HTMLButtonElement>("#select-export");
const exportInput = document.querySelector<HTMLInputElement>("#export-file");
const exportSummary = document.querySelector<HTMLElement>("#export-summary");
const exportSummaryTitle = document.querySelector<HTMLElement>("#export-summary-title");
const exportSummaryMeta = document.querySelector<HTMLParagraphElement>("#export-summary-meta");
const previousExportPanel = document.querySelector<HTMLElement>("#previous-export");
const previousExportTitle = document.querySelector<HTMLElement>("#previous-export-title");
const previousExportMeta = document.querySelector<HTMLParagraphElement>("#previous-export-meta");
const previousExportLink = document.querySelector<HTMLAnchorElement>("#previous-export-link");
const titleInput = document.querySelector<HTMLInputElement>("#document-title");
const subpageModeInputs = Array.from(
  document.querySelectorAll<HTMLInputElement>('input[name="subpage-mode"]'),
);
const taskPanel = document.querySelector<HTMLElement>("#task-panel");
const taskStatusBadge = document.querySelector<HTMLElement>("#task-status-badge");
const taskStage = document.querySelector<HTMLElement>("#task-stage");
const taskPercent = document.querySelector<HTMLElement>("#task-percent");
const taskMessage = document.querySelector<HTMLElement>("#task-message");
const progressTrack = document.querySelector<HTMLElement>(".progress-track");
const progressBar = document.querySelector<HTMLElement>("#progress-bar");
const cancelButton = document.querySelector<HTMLButtonElement>("#cancel-task");
const recoveryPanel = document.querySelector<HTMLElement>("#recovery-panel");
const recoveryTitle = document.querySelector<HTMLElement>("#recovery-title");
const recoveryMessage = document.querySelector<HTMLElement>("#recovery-message");
const recoveryButton = document.querySelector<HTMLButtonElement>("#recovery-action");
const resultPanel = document.querySelector<HTMLElement>("#result-panel");
const resultTitle = document.querySelector<HTMLElement>("#result-title");
const resultSummary = document.querySelector<HTMLParagraphElement>("#result-summary");
const resultLink = document.querySelector<HTMLAnchorElement>("#result-link");
const authStatus = document.querySelector<HTMLElement>("#auth-status");
const targetStatus = document.querySelector<HTMLElement>("#target-status");
const loginButton = document.querySelector<HTMLButtonElement>("#login-dingtalk");
const targetButton = document.querySelector<HTMLButtonElement>("#select-target");
const settingsActionStatus = document.querySelector<HTMLParagraphElement>("#settings-action-status");
const localSetup = document.querySelector<HTMLElement>("#local-setup");
const localSetupKicker = document.querySelector<HTMLElement>("#local-setup-kicker");
const localSetupTitle = document.querySelector<HTMLElement>("#local-setup-title");
const localSetupMessage = document.querySelector<HTMLParagraphElement>("#local-setup-message");
const localSetupDownload = document.querySelector<HTMLAnchorElement>("#local-setup-download");
const localSetupRelease = document.querySelector<HTMLAnchorElement>("#local-setup-release");
const settingsPanel = document.querySelector<HTMLElement>("#settings-panel");
const migrationPanel = document.querySelector<HTMLElement>("#migration-panel");

let currentPage: PageSnapshot | undefined;
let currentPageIdentity: string | undefined;
let localToolReady = false;
let localToolInstalled = false;
let migrating = false;
let inspectingExport = false;
let actionOpening = false;
let polling = false;
let activeTaskId: string | undefined;
let latestSnapshot: MigrationTaskSnapshot | undefined;
let selectedExport: SelectedExport | undefined;
let exportSelectionStarted = false;

const actionLabels = {
  login: { idle: "更改", busy: "打开中…" },
  target: { idle: "更改", busy: "读取中…" },
} as const;

const stageLabels: Record<string, string> = {
  queued: "等待本地核心",
  preflight: "检查环境与导出包",
  convert: "转换 Notion 内容",
  import: "写入钉钉文档",
  verify: "回读并核对结果",
  cleanup: "清理临时数据",
  succeeded: "迁移完成",
  failed: "迁移未完成",
  unknown: "等待人工确认",
  cancelled: "迁移已取消",
};

function setStatus(
  element: HTMLElement | null,
  message: string,
  kind: "idle" | "success" | "warning" | "error",
): void {
  if (!element) return;
  element.textContent = message;
  element.dataset.kind = kind;
}

function setWorkspaceVisible(visible: boolean): void {
  if (settingsPanel) settingsPanel.hidden = !visible;
  if (migrationPanel) migrationPanel.hidden = !visible;
}

function hideLocalSetup(): void {
  if (localSetup) localSetup.hidden = true;
}

function showLocalSetup(action: "install" | "upgrade", message: string): void {
  setWorkspaceVisible(false);
  if (localSetup) localSetup.hidden = false;
  if (localSetupKicker) localSetupKicker.textContent = action === "install" ? "首次设置" : "需要升级";
  if (localSetupTitle) {
    localSetupTitle.textContent = action === "install"
      ? "安装 Windows 本地助手"
      : "升级 Windows 本地助手";
  }
  if (localSetupMessage) localSetupMessage.textContent = message;
  if (localSetupDownload) {
    localSetupDownload.href = INSTALLER_URL;
    localSetupDownload.textContent = action === "install" ? "下载并安装" : "下载最新版";
  }
  if (localSetupRelease) localSetupRelease.href = RELEASES_URL;
}

function updateButtons(): void {
  if (checkButton) checkButton.disabled = migrating || actionOpening;
  if (selectExportButton) {
    selectExportButton.disabled = migrating || actionOpening || inspectingExport || !localToolReady;
  }
  if (migrateButton) {
    migrateButton.disabled = migrating || actionOpening || inspectingExport || !localToolReady || !selectedExport;
  }
  if (loginButton) loginButton.disabled = migrating || actionOpening || !localToolInstalled;
  if (targetButton) targetButton.disabled = migrating || actionOpening || !localToolInstalled;
  for (const input of subpageModeInputs) input.disabled = migrating || actionOpening;
  if (titleInput) titleInput.disabled = migrating || actionOpening || inspectingExport || !selectedExport;
}

function setActionBusy(
  action: "login" | "target",
  button: HTMLButtonElement | null,
  busy: boolean,
): void {
  if (!button) return;
  button.textContent = busy ? actionLabels[action].busy : actionLabels[action].idle;
  button.classList.toggle("busy", busy);
  button.setAttribute("aria-busy", String(busy));
}

function showActionProgress(message: string, busy: boolean): void {
  if (!settingsActionStatus) return;
  settingsActionStatus.textContent = message;
  settingsActionStatus.dataset.kind = busy ? "busy" : "idle";
  settingsActionStatus.hidden = false;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
}

function sendExtensionMessage<TResult>(message: unknown): Promise<ExtensionReply<TResult>> {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage(message, (reply?: ExtensionReply<TResult>) => {
      const runtimeError = chrome.runtime.lastError;
      if (runtimeError) {
        resolve({ ok: false, error: runtimeError.message ?? "扩展内部通信失败。" });
        return;
      }
      resolve(reply ?? { ok: false, error: "扩展后台没有返回结果。" });
    });
  });
}

async function abortExportTransfer(transferId: string): Promise<void> {
  await sendExtensionMessage({
    type: "native.export.transfer.abort",
    params: { transferId },
  });
}

async function sendExportTransfer<TResult>(
  operation: "inspect" | "start",
  file: File,
  contentBase64: string,
  migration?: Omit<MigrationExportParams, "fileName" | "contentBase64">,
  onProgress?: (completed: number, total: number) => void,
): Promise<ExtensionReply<TResult>> {
  const transferId = crypto.randomUUID();
  const totalChunks = Math.ceil(contentBase64.length / exportTransferChunkCharacters);
  const begin = await sendExtensionMessage({
    type: "native.export.transfer.begin",
    params: {
      transferId,
      fileName: file.name,
      rawBytes: file.size,
      encodedCharacters: contentBase64.length,
      totalChunks,
    },
  });
  if (!begin.ok) return begin as ExtensionReply<TResult>;

  for (let index = 0; index < totalChunks; index += 1) {
    const start = index * exportTransferChunkCharacters;
    const chunk = await sendExtensionMessage({
      type: "native.export.transfer.chunk",
      params: {
        transferId,
        index,
        contentBase64: contentBase64.slice(start, start + exportTransferChunkCharacters),
      },
    });
    if (!chunk.ok) {
      await abortExportTransfer(transferId);
      return chunk as ExtensionReply<TResult>;
    }
    onProgress?.(index + 1, totalChunks);
  }

  const reply = await sendExtensionMessage<TResult>({
    type: "native.export.transfer.commit",
    params: { transferId, operation, migration },
  });
  if (!reply.ok) await abortExportTransfer(transferId);
  return reply;
}

function saveActiveTask(taskId: string): Promise<void> {
  return new Promise((resolve) => {
    if (!currentPageIdentity) {
      chrome.storage.session.remove(activeTaskStorageKey, () => resolve());
      return;
    }
    const reference: StoredTaskReference = {
      taskId,
      sourcePageIdentity: currentPageIdentity,
    };
    chrome.storage.session.set({ [activeTaskStorageKey]: reference }, () => resolve());
  });
}

function clearActiveTask(): Promise<void> {
  return new Promise((resolve) => {
    chrome.storage.session.remove(activeTaskStorageKey, () => resolve());
  });
}

function readActiveTask(): Promise<StoredTaskReference | undefined> {
  return new Promise((resolve) => {
    chrome.storage.session.get(activeTaskStorageKey, (values) => {
      const value = values[activeTaskStorageKey];
      const candidate = value as Partial<StoredTaskReference> | null;
      if (
        typeof value === "object" && value !== null &&
        typeof candidate?.taskId === "string" && candidate.taskId.length > 0 &&
        typeof candidate.sourcePageIdentity === "string" && candidate.sourcePageIdentity.length > 0
      ) {
        resolve(candidate as StoredTaskReference);
        return;
      }
      resolve(undefined);
    });
  });
}

async function checkNativeHost(): Promise<void> {
  localToolReady = false;
  localToolInstalled = false;
  hideLocalSetup();
  setWorkspaceVisible(false);
  if (authStatus) authStatus.textContent = "正在检查…";
  if (targetStatus) targetStatus.textContent = "正在检查…";
  updateButtons();
  setStatus(hostStatus, "正在检查 Native Host 与本地迁移核心…", "idle");
  const reply = await sendExtensionMessage<HealthResult>({ type: "native.health" });
  const health = reply.response?.result;
  if (!reply.ok || !health) {
    const message = reply.error ?? "尚未连接 Native Host。请先安装 Windows 本地助手。";
    setStatus(hostStatus, message, "error");
    showLocalSetup("install", "Edge 扩展已经安装；再运行一次 Windows 本地助手安装包，即可在本机安全转换并写入钉钉。 ");
    if (authStatus) authStatus.textContent = "无法读取";
    if (targetStatus) targetStatus.textContent = "无法读取";
    updateButtons();
    return;
  }
  localToolInstalled = health.localTool.installed;
  const compatibility = evaluateCompatibility(health);
  if (!compatibility.compatible) {
    setStatus(hostStatus, compatibility.message, "error");
    showLocalSetup(compatibility.action, compatibility.message);
    if (authStatus) authStatus.textContent = "等待本地助手";
    if (targetStatus) targetStatus.textContent = "等待本地助手";
    updateButtons();
    return;
  }
  hideLocalSetup();
  setWorkspaceVisible(true);
  if (authStatus) authStatus.textContent = health.localTool.authenticated ? "已登录" : "需要登录";
  if (targetStatus) {
    targetStatus.textContent = health.localTool.configured
      ? health.localTool.targetDisplayName ?? "已配置"
      : "尚未选择";
    targetStatus.title = health.localTool.targetDisplayName ?? "";
  }
  if (!health.localTool.ready) {
    setStatus(
      hostStatus,
      `Native Host ${health.hostVersion} 已连接；${health.localTool.message}`,
      "warning",
    );
    updateButtons();
    return;
  }
  localToolReady = true;
  setStatus(
    hostStatus,
    `Host ${health.hostVersion} · Core ${health.localTool.version ?? "未知"} · ${health.platform}`,
    "success",
  );
  updateButtons();
}

async function openLocalTool(action: "login" | "target"): Promise<void> {
  if (!localToolInstalled) {
    setStatus(hostStatus, "尚未安装 Windows 本地工具。", "error");
    return;
  }
  if (actionOpening) return;
  const button = action === "login" ? loginButton : targetButton;
  actionOpening = true;
  setActionBusy(action, button, true);
  updateButtons();
  const loadingMessage = action === "login"
    ? "正在启动钉钉授权，浏览器窗口出现前请稍候…"
    : "正在读取钉钉空间和目录，通常需要 3–10 秒，请勿重复点击…";
  showActionProgress(loadingMessage, true);
  try {
    const reply = await sendExtensionMessage<LocalOpenResult>({
      type: "native.open",
      params: { action },
    });
    const result = reply.response?.result;
    if (!reply.ok || !result?.started) {
      showActionProgress(reply.error ?? "Windows 设置窗口未能打开，可以再次点击重试。", false);
      return;
    }
    await delay(action === "target" ? 8_000 : 4_000);
    showActionProgress("窗口已经打开；完成设置后点击右上角 ↻ 重新检查。", false);
  } finally {
    actionOpening = false;
    setActionBusy(action, button, false);
    updateButtons();
  }
}

async function inspectCurrentPage(): Promise<void> {
  currentPage = undefined;
  currentPageIdentity = undefined;
  setStatus(pageStatus, "正在识别当前页面…", "idle");
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  const tab = tabs[0];
  if (!tab?.id || !tab.url) {
    setStatus(pageStatus, "无法读取当前标签页；仍可选择 Notion HTML 导出 ZIP。", "warning");
    return;
  }
  if (!isSupportedNotionURL(tab.url)) {
    let currentHost = "未知地址";
    try {
      const parsed = new URL(tab.url);
      currentHost = parsed.hostname || parsed.protocol;
    } catch {
      // 不回显无法解析的完整地址。
    }
    setStatus(pageStatus, `${currentHost} 不是 Notion 页面；仍可迁移 HTML ZIP。`, "warning");
    return;
  }
  currentPageIdentity = getNotionPageIdentity(tab.url);

  try {
    const execution = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: (mustExport: true) => {
        const title =
          document.querySelector<HTMLElement>("h1")?.innerText.trim() ||
          document.title.replace(/\s*[|–-]\s*Notion\s*$/iu, "").trim() ||
          "Notion 页面";
        const visibleBlocks = new Set<HTMLElement>();
        document
          .querySelectorAll<HTMLElement>("[data-block-id], [data-content-editable-leaf]")
          .forEach((element) => visibleBlocks.add(element));
        const visibleImages = Array.from(document.images).filter((image) => {
          const rect = image.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        });
        return {
          url: location.href,
          title,
          visibleTextBytes: new TextEncoder().encode(document.body?.innerText ?? "").length,
          visibleBlockCount: visibleBlocks.size,
          visibleImageCount: visibleImages.length,
          exportRequired: mustExport,
        };
      },
      args: [requiresOfficialHTMLExport()],
    });
    currentPage = execution[0]?.result;
    if (!currentPage) throw new Error("页面脚本没有返回识别结果");
    setStatus(
      pageStatus,
      `《${currentPage.title}》 · ${currentPage.visibleBlockCount} 个块 · ${currentPage.visibleImageCount} 张图片 · 以 HTML ZIP 为准`,
      "success",
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    setStatus(pageStatus, `页面识别未完成：${message}。仍可迁移官方 HTML ZIP。`, "warning");
  }
}

function encodeBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  const chunks: string[] = [];
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    chunks.push(String.fromCharCode(...bytes.subarray(offset, offset + chunkSize)));
  }
  return btoa(chunks.join(""));
}

function formatExportTime(value: string): string {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return value;
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(parsed);
}

function clearSelectedExport(): void {
  selectedExport = undefined;
  if (!migrating) {
    activeTaskId = undefined;
    latestSnapshot = undefined;
    void clearActiveTask();
  }
  if (titleInput) titleInput.value = "";
  if (exportSummary) {
    exportSummary.hidden = true;
    delete exportSummary.dataset.kind;
  }
  if (exportSummaryTitle) exportSummaryTitle.textContent = "尚未选择导出包";
  if (exportSummaryMeta) exportSummaryMeta.textContent = "";
  if (previousExportPanel) {
    previousExportPanel.hidden = true;
    delete previousExportPanel.dataset.kind;
  }
  if (previousExportLink) previousExportLink.removeAttribute("href");
  if (migrateButton) migrateButton.textContent = "开始转换";
  updateButtons();
}

function showPreviousExport(inspection: MigrationExportInspection): void {
  const previous = inspection.previousExport;
  if (!previous || !previousExportPanel || !previousExportLink) return;
  previousExportPanel.hidden = false;
  previousExportPanel.dataset.kind = previous.status;
  if (previousExportTitle) {
    previousExportTitle.textContent = previous.status === "success"
      ? "此前已导出"
      : "此前可能已导出";
  }
  if (previousExportMeta) {
    const mode = previous.subpageMode === "tree" ? "递归文档树" : "同页展开";
    previousExportMeta.textContent = `${previous.count} 条相同导出包记录 · ${formatExportTime(previous.updatedAt)} · ${mode}`;
  }
  previousExportLink.href = previous.documentUrl;
  previousExportLink.textContent = previous.status === "success"
    ? "打开此前的钉钉文档 ↗"
    : "打开可能已创建的钉钉文档 ↗";
  if (migrateButton) {
    migrateButton.textContent = previous.status === "success"
      ? "仍再次导出"
      : "再次导出为新文档";
  }
}

function showExportInspection(inspection: MigrationExportInspection): void {
  if (exportSummary) {
    exportSummary.hidden = false;
    exportSummary.dataset.kind = "success";
  }
  if (exportSummaryTitle) exportSummaryTitle.textContent = `《${inspection.title}》`;
  if (exportSummaryMeta) {
    exportSummaryMeta.textContent = `${inspection.fileName} · 导出时间 ${formatExportTime(inspection.exportedAt)} · ${inspection.pageCount} 页`;
  }
  showPreviousExport(inspection);
}

function showExportInspectionError(message: string): void {
  if (exportSummary) {
    exportSummary.hidden = false;
    exportSummary.dataset.kind = "error";
  }
  if (exportSummaryTitle) exportSummaryTitle.textContent = "导出包无法使用";
  if (exportSummaryMeta) exportSummaryMeta.textContent = message;
}

async function inspectExportFile(file: File): Promise<void> {
  exportSelectionStarted = true;
  clearSelectedExport();
  if (!localToolReady) {
    setStatus(hostStatus, "本地迁移核心尚未就绪；请先完成上方检查。", "error");
    return;
  }
  if (!file.name.toLowerCase().endsWith(".zip") || file.size <= 0) {
    showExportInspectionError("请选择单个 Notion HTML 导出 ZIP。");
    return;
  }
  if (file.size > maxExportBytes) {
    showExportInspectionError("导出 ZIP 超过 46 MiB；请使用 Windows 一键工具迁移。");
    return;
  }

  inspectingExport = true;
  if (selectExportButton) selectExportButton.textContent = "正在解析导出包…";
  if (exportSummary) exportSummary.hidden = false;
  if (exportSummaryTitle) exportSummaryTitle.textContent = "正在读取标题和导出时间…";
  if (exportSummaryMeta) exportSummaryMeta.textContent = file.name;
  if (taskPanel) taskPanel.hidden = true;
  if (recoveryPanel) recoveryPanel.hidden = true;
  if (resultPanel) resultPanel.hidden = true;
  updateButtons();
  try {
    const contentBase64 = encodeBase64(await file.arrayBuffer());
    const reply = await sendExportTransfer<MigrationExportInspection>(
      "inspect",
      file,
      contentBase64,
      undefined,
      (completed, total) => {
        if (selectExportButton) {
          selectExportButton.textContent = `正在读取导出包 ${Math.round((completed / total) * 100)}%…`;
        }
      },
    );
    const inspection = reply.response?.result;
    if (!reply.ok || !inspection) {
      showExportInspectionError(reply.error ?? "导出包预检失败，请重新选择。");
      return;
    }
    selectedExport = { file, contentBase64, inspection };
    if (titleInput) titleInput.value = inspection.title.slice(0, titleInput.maxLength || 200);
    showExportInspection(inspection);
  } catch (error) {
    showExportInspectionError(error instanceof Error ? error.message : String(error));
  } finally {
    inspectingExport = false;
    if (selectExportButton) {
      selectExportButton.textContent = selectedExport ? "重新选择 HTML 导出 ZIP" : "选择 HTML 导出 ZIP";
    }
    updateButtons();
  }
}

function setProgress(percent: number): void {
  const safePercent = Math.max(0, Math.min(100, Math.round(percent)));
  if (progressBar) progressBar.style.width = `${safePercent}%`;
  if (taskPercent) taskPercent.textContent = `${safePercent}%`;
  progressTrack?.setAttribute("aria-valuenow", String(safePercent));
}

function showTaskPreparing(message: string): void {
  if (taskPanel) taskPanel.hidden = false;
  if (recoveryPanel) recoveryPanel.hidden = true;
  if (resultPanel) resultPanel.hidden = true;
  if (taskStatusBadge) {
    taskStatusBadge.textContent = "准备中";
    taskStatusBadge.dataset.kind = "active";
  }
  if (taskStage) taskStage.textContent = "安全读取导出包";
  if (taskMessage) taskMessage.textContent = message;
  if (cancelButton) cancelButton.hidden = true;
  setProgress(1);
}

function resultSummaryText(result: MigrationResult): string {
  const subpages = result.subpageMode === "tree"
    ? `递归树 ${result.recursivePageCount ?? 0} 页 / ${result.recursiveFolderCount ?? 0} 个文件夹 / ${result.recursiveLinkCount ?? 0} 个链接`
    : `同页目录 ${result.nativeSubpageTocItemCount ?? 0} 项`;
  return `图片 ${result.readbackImageCount}/${result.expectedImageCount} · ${subpages} · 分栏 ${result.nativeLayoutCount ?? 0} · 待办 ${result.nativeTodoCount} · 代码块 ${result.nativeCodeBlockCount ?? 0} · 临时数据已清理`;
}

function showResult(result: MigrationResult, verified: boolean): void {
  if (!resultPanel || !resultSummary || !resultLink) return;
  resultPanel.hidden = false;
  if (resultTitle) {
    resultTitle.textContent = verified
      ? result.reused ? "已复用原迁移结果" : "迁移与回读验证完成"
      : "远端结果需要人工确认";
  }
  resultSummary.textContent = verified
    ? resultSummaryText(result)
    : "钉钉可能已经写入文档。你可以打开链接确认，也可以按需再次导入为新文档。";
  resultLink.textContent = result.subpageMode === "tree" ? "打开钉钉根文档 ↗" : "打开钉钉文档 ↗";
  resultLink.href = result.documentUrl;
}

function recoveryLabel(snapshot: MigrationTaskSnapshot): string {
  if (snapshot.status === "unknown" && selectedExport) return "再次导入为新文档";
  switch (snapshot.recoveryAction) {
    case "login": return "前往登录";
    case "target": return "更改保存位置";
    case "select_export": return "重新选择导出包";
    case "recover": return snapshot.result?.documentUrl ? "打开文档确认" : "重新检查环境";
    default: return selectedExport ? "重试此导出包" : "重新选择导出包";
  }
}

function showRecovery(snapshot: MigrationTaskSnapshot): void {
  if (!recoveryPanel || !recoveryMessage || !recoveryButton) return;
  recoveryPanel.hidden = false;
  if (recoveryTitle) {
    recoveryTitle.textContent = snapshot.status === "unknown"
      ? "本次写入状态未确认"
      : snapshot.status === "cancelled" ? "迁移已取消" : "迁移未完成";
  }
  recoveryMessage.textContent = snapshot.error?.message ?? snapshot.progress.message;
  recoveryButton.textContent = recoveryLabel(snapshot);
  recoveryButton.hidden = snapshot.recoveryAction === "recover" && !snapshot.result?.documentUrl && !localToolInstalled;
}

function renderSnapshot(snapshot: MigrationTaskSnapshot): void {
  latestSnapshot = snapshot;
  const isActive = activeStatuses.has(snapshot.status);
  migrating = isActive;
  updateButtons();
  if (taskPanel) taskPanel.hidden = !isActive;
  if (recoveryPanel) recoveryPanel.hidden = true;
  if (resultPanel) resultPanel.hidden = true;

  if (isActive) {
    if (taskStatusBadge) {
      taskStatusBadge.textContent = snapshot.status === "cancel_requested" ? "正在取消" : "迁移中";
      taskStatusBadge.dataset.kind = "active";
    }
    if (taskStage) taskStage.textContent = stageLabels[snapshot.progress.stage] ?? "正在迁移";
    if (taskMessage) taskMessage.textContent = snapshot.progress.message;
    if (cancelButton) {
      cancelButton.hidden = snapshot.status !== "cancel_requested" && !snapshot.canCancel;
      cancelButton.disabled = !snapshot.canCancel;
      cancelButton.textContent = snapshot.status === "cancel_requested" ? "正在停止…" : "取消迁移";
    }
    setProgress(snapshot.progress.percent);
    return;
  }

  if (snapshot.status === "succeeded" && snapshot.result) {
    showResult(snapshot.result, true);
    return;
  }
  if (snapshot.result?.documentUrl && snapshot.status === "unknown") {
    showResult(snapshot.result, false);
  }
  showRecovery(snapshot);
}

async function pollActiveTask(): Promise<void> {
  if (polling || !activeTaskId) return;
  polling = true;
  try {
    while (activeTaskId) {
      const taskId: string = activeTaskId;
      const reply = await sendExtensionMessage<MigrationTaskSnapshot>({
        type: "native.task.status",
        params: { taskId },
      });
      const snapshot = reply.response?.result;
      if (activeTaskId !== taskId) return;
      if (!reply.ok || !snapshot) {
        migrating = false;
        updateButtons();
        await clearActiveTask();
        activeTaskId = undefined;
        const fallback: MigrationTaskSnapshot = {
          taskId,
          status: "failed",
          progress: { current: 0, total: 5, percent: 0, stage: "failed", message: reply.error ?? "无法恢复迁移任务。" },
          canCancel: false,
          recoveryAction: "select_export",
          updatedAt: new Date().toISOString(),
          error: { code: "task_unavailable", message: reply.error ?? "Native Host 已重启，请重新选择导出包。" },
        };
        renderSnapshot(fallback);
        return;
      }
      renderSnapshot(snapshot);
      if (!activeStatuses.has(snapshot.status)) return;
      await delay(650);
    }
  } finally {
    polling = false;
  }
}

async function startMigration(): Promise<void> {
  if (!localToolReady) {
    setStatus(hostStatus, "本地迁移核心尚未就绪；请先完成上方检查。", "error");
    return;
  }
  if (!selectedExport) {
    showExportInspectionError("请先选择并确认一个 Notion HTML 导出 ZIP。");
    return;
  }

  const preparedExport = selectedExport;
  migrating = true;
  latestSnapshot = undefined;
  updateButtons();
  showTaskPreparing(`已确认《${preparedExport.inspection.title}》，正在启动转换。`);
  try {
    const params: Omit<MigrationExportParams, "fileName" | "contentBase64"> = {
      createNew: true,
      subpageMode: subpageModeInputs.find((input) => input.checked)?.value === "tree"
        ? "tree"
        : "inline",
    };
    if (currentPage) params.sourcePage = currentPage;
    const requestedTitle = titleInput?.value.trim();
    if (requestedTitle) params.title = requestedTitle;
    const reply = await sendExportTransfer<MigrationTaskSnapshot>(
      "start",
      preparedExport.file,
      preparedExport.contentBase64,
      params,
      (completed, total) => {
        if (taskMessage) {
          taskMessage.textContent = `正在安全传输导出包 ${Math.round((completed / total) * 100)}%…`;
        }
      },
    );
    const snapshot = reply.response?.result;
    if (!reply.ok || !snapshot) {
      const failure: MigrationTaskSnapshot = {
        taskId: "not-started",
        status: "failed",
        progress: { current: 0, total: 5, percent: 0, stage: "failed", message: reply.error ?? "迁移任务未能启动。" },
        canCancel: false,
        recoveryAction: "retry",
        updatedAt: new Date().toISOString(),
        error: reply.response?.error ?? { code: "migration_start_failed", message: reply.error ?? "迁移任务未能启动。" },
      };
      renderSnapshot(failure);
      return;
    }
    activeTaskId = snapshot.taskId;
    await saveActiveTask(snapshot.taskId);
    renderSnapshot(snapshot);
    void pollActiveTask();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const failure: MigrationTaskSnapshot = {
      taskId: "not-started",
      status: "failed",
      progress: { current: 0, total: 5, percent: 0, stage: "failed", message },
      canCancel: false,
      recoveryAction: "retry",
      updatedAt: new Date().toISOString(),
      error: { code: "migration_start_failed", message },
    };
    renderSnapshot(failure);
  } finally {
    if (!activeTaskId) {
      migrating = false;
      updateButtons();
    }
  }
}

async function cancelMigration(): Promise<void> {
  if (!activeTaskId || !latestSnapshot?.canCancel) return;
  if (cancelButton) {
    cancelButton.disabled = true;
    cancelButton.textContent = "正在停止…";
  }
  const reply = await sendExtensionMessage<MigrationTaskSnapshot>({
    type: "native.task.cancel",
    params: { taskId: activeTaskId },
  });
  const snapshot = reply.response?.result;
  if (reply.ok && snapshot) {
    renderSnapshot(snapshot);
    void pollActiveTask();
    return;
  }
  if (taskMessage) taskMessage.textContent = reply.error ?? "取消请求未能发送，请稍后重试。";
  if (cancelButton) cancelButton.disabled = false;
}

async function handleRecovery(): Promise<void> {
  const snapshot = latestSnapshot;
  if (!snapshot) {
    exportInput?.click();
    return;
  }
  if (snapshot.status === "unknown" && selectedExport) {
    await startMigration();
    return;
  }
  if (snapshot.recoveryAction === "login") {
    await openLocalTool("login");
    return;
  }
  if (snapshot.recoveryAction === "target") {
    await openLocalTool("target");
    return;
  }
  if (snapshot.recoveryAction === "recover") {
    if (snapshot.result?.documentUrl) {
      window.open(snapshot.result.documentUrl, "_blank", "noopener,noreferrer");
    } else {
      await checkNativeHost();
    }
    return;
  }
  if (snapshot.recoveryAction !== "select_export" && selectedExport) {
    await startMigration();
    return;
  }
  exportInput?.click();
}

async function resumeStoredTask(): Promise<void> {
  const storedTask = await readActiveTask();
  if (exportSelectionStarted || inspectingExport || selectedExport) return;
  if (!storedTask || !taskBelongsToCurrentPage(storedTask.sourcePageIdentity, currentPageIdentity)) return;
  activeTaskId = storedTask.taskId;
  migrating = true;
  updateButtons();
  showTaskPreparing("正在恢复上次迁移的实时状态…");
  void pollActiveTask();
}

checkButton?.addEventListener("click", () => void checkNativeHost());
loginButton?.addEventListener("click", () => void openLocalTool("login"));
targetButton?.addEventListener("click", () => void openLocalTool("target"));
selectExportButton?.addEventListener("click", () => exportInput?.click());
migrateButton?.addEventListener("click", () => void startMigration());
cancelButton?.addEventListener("click", () => void cancelMigration());
recoveryButton?.addEventListener("click", () => void handleRecovery());
exportInput?.addEventListener("change", () => {
  const file = exportInput.files?.[0];
  exportInput.value = "";
  if (file) void inspectExportFile(file);
});

async function initializePopup(): Promise<void> {
  await Promise.all([checkNativeHost(), inspectCurrentPage()]);
  await resumeStoredTask();
}

void initializePopup();
