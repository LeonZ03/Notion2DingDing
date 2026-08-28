import type { HealthResult } from "./protocol.js";

export const MINIMUM_HOST_VERSION = "0.3.3";
export const MINIMUM_LOCAL_TOOL_VERSION = "0.1.0";
export const RELEASES_URL = "https://github.com/LeonZ03/Notion2DingDing/releases/latest";
export const INSTALLER_URL = `${RELEASES_URL}/download/Notion2DingDing-Setup.exe`;

const requiredCapabilities = [
  "health.check",
  "local.open",
  "migration.inspect",
  "migration.start",
  "migration.status",
  "migration.cancel",
] as const;

export type CompatibilityResult =
  | { compatible: true }
  | { compatible: false; action: "install" | "upgrade"; message: string };

function numericVersion(value: string): number[] | undefined {
  const match = value.trim().match(/^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/u);
  if (!match) return undefined;
  return match.slice(1).map(Number);
}

export function isVersionAtLeast(actual: string, minimum: string): boolean {
  const actualParts = numericVersion(actual);
  const minimumParts = numericVersion(minimum);
  if (!actualParts || !minimumParts) return false;
  for (let index = 0; index < minimumParts.length; index += 1) {
    const actualPart = actualParts[index] ?? 0;
    const minimumPart = minimumParts[index] ?? 0;
    if (actualPart > minimumPart) return true;
    if (actualPart < minimumPart) return false;
  }
  return true;
}

export function evaluateCompatibility(health: HealthResult): CompatibilityResult {
  if (!health.localTool.installed) {
    return {
      compatible: false,
      action: "install",
      message: "Edge 扩展已安装，还需要安装一次 Windows 本地助手。",
    };
  }

  if (!isVersionAtLeast(health.hostVersion, MINIMUM_HOST_VERSION)) {
    return {
      compatible: false,
      action: "upgrade",
      message: `Native Host ${health.hostVersion} 版本过低，需要 ${MINIMUM_HOST_VERSION} 或更高版本。`,
    };
  }

  const localToolVersion = health.localTool.version ?? "";
  if (!isVersionAtLeast(localToolVersion, MINIMUM_LOCAL_TOOL_VERSION)) {
    return {
      compatible: false,
      action: "upgrade",
      message: `本地核心 ${localToolVersion || "未知"} 与当前扩展不兼容，请升级本地助手。`,
    };
  }

  const missingCapabilities = requiredCapabilities.filter(
    (capability) => !health.capabilities.includes(capability),
  );
  if (missingCapabilities.length > 0) {
    return {
      compatible: false,
      action: "upgrade",
      message: "本地助手缺少当前扩展需要的能力，请安装最新版。",
    };
  }

  return { compatible: true };
}
