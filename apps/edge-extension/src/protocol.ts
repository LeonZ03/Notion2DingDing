export const NATIVE_HOST_NAME = "com.leonz03.notion2dingding";
export const PROTOCOL_VERSION = 1 as const;

export interface NativeRequest<TParams = unknown> {
  protocolVersion: typeof PROTOCOL_VERSION;
  requestId: string;
  method: string;
  params: TParams;
}

export interface NativeError {
  code: string;
  message: string;
  details?: Record<string, unknown>;
}

export interface NativeResponse<TResult = unknown> {
  protocolVersion: typeof PROTOCOL_VERSION;
  requestId: string;
  ok: boolean;
  result?: TResult;
  error?: NativeError;
}

export interface HealthResult {
  hostVersion: string;
  protocolVersion: typeof PROTOCOL_VERSION;
  platform: string;
  capabilities: string[];
  localTool: {
    installed: boolean;
    version?: string;
    ready: boolean;
    authenticated: boolean;
    configured: boolean;
    targetType?: "folder" | "workspace";
    targetDisplayName?: string;
    message: string;
  };
}

export interface LocalOpenParams {
  action: "login" | "target";
}

export interface LocalOpenResult {
  started: boolean;
  action: "login" | "target";
  message: string;
}

export interface PageSnapshot {
  url: string;
  title: string;
  visibleTextBytes: number;
  visibleBlockCount: number;
  visibleImageCount: number;
  exportRequired: true;
}

export interface MigrationExportParams {
  fileName: string;
  contentBase64: string;
  title?: string;
  subpageMode?: "inline" | "tree";
  createNew?: boolean;
  sourcePage?: PageSnapshot;
}

export interface MigrationExportInspection {
  fileName: string;
  title: string;
  exportedAt: string;
  pageCount: number;
  bytes: number;
  previousExport?: MigrationPreviousExport;
}

export interface MigrationPreviousExport {
  status: "success" | "unknown";
  documentUrl: string;
  updatedAt: string;
  count: number;
  subpageMode: "inline" | "tree";
}

export interface MigrationResult {
  taskId: string;
  remoteTaskId?: string;
  documentUrl: string;
  reused: boolean;
  expectedImageCount: number;
  readbackImageCount: number;
  nativeTodoCount: number;
  nativeCodeBlockCount?: number;
  nativeLayoutCount?: number;
  nativeSubpageTocItemCount?: number;
  subpageMode?: "inline" | "tree";
  recursivePageCount?: number;
  recursiveFolderCount?: number;
  recursiveLinkCount?: number;
  cleanupVerified: boolean;
  sourcePageCaptured: boolean;
}

export interface MigrationTaskParams {
  taskId: string;
}

export type MigrationTaskStatus =
  | "queued"
  | "running"
  | "cancel_requested"
  | "succeeded"
  | "failed"
  | "unknown"
  | "cancelled";

export interface MigrationTaskProgress {
  current: number;
  total: number;
  percent: number;
  stage: string;
  message: string;
}

export interface MigrationTaskSnapshot {
  taskId: string;
  status: MigrationTaskStatus;
  progress: MigrationTaskProgress;
  canCancel: boolean;
  recoveryAction?: "login" | "target" | "select_export" | "retry" | "recover";
  updatedAt: string;
  result?: MigrationResult;
  error?: NativeError;
}

export function createRequest<TParams>(
  method: string,
  params: TParams,
): NativeRequest<TParams> {
  return {
    protocolVersion: PROTOCOL_VERSION,
    requestId: crypto.randomUUID(),
    method,
    params,
  };
}

export function isNativeResponse(value: unknown): value is NativeResponse {
  if (typeof value !== "object" || value === null) {
    return false;
  }

  const candidate = value as Partial<NativeResponse>;
  const envelopeValid =
    candidate.protocolVersion === PROTOCOL_VERSION &&
    typeof candidate.requestId === "string" &&
    typeof candidate.ok === "boolean";
  if (!envelopeValid) {
    return false;
  }
  if (candidate.ok) {
    return candidate.error === undefined;
  }
  return (
    typeof candidate.error?.code === "string" &&
    typeof candidate.error.message === "string"
  );
}
