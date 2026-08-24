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
  platform: string;
  capabilities: string[];
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
  return (
    candidate.protocolVersion === PROTOCOL_VERSION &&
    typeof candidate.requestId === "string" &&
    typeof candidate.ok === "boolean"
  );
}
