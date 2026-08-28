export function isSupportedNotionURL(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.protocol !== "https:") {
    return false;
  }
  const host = url.hostname.toLowerCase();
  return (
    host === "notion.com" ||
    host === "www.notion.com" ||
    host === "app.notion.com" ||
    host === "notion.so" ||
    host.endsWith(".notion.so") ||
    host === "notion.site" ||
    host.endsWith(".notion.site")
  );
}

export function getNotionPageIdentity(value: string): string | undefined {
  if (!isSupportedNotionURL(value)) return undefined;
  const url = new URL(value);
  const pageId = url.pathname.match(
    /(?<id>[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:\/)?$/iu,
  )?.groups?.id;
  if (pageId) return pageId.replaceAll("-", "").toLowerCase();
  const normalizedPath = url.pathname.replace(/\/+$/u, "") || "/";
  return `${url.hostname.toLowerCase()}${normalizedPath}`;
}

export function taskBelongsToCurrentPage(
  storedPageIdentity: string | undefined,
  currentPageIdentity: string | undefined,
): boolean {
  return Boolean(
    storedPageIdentity && currentPageIdentity && storedPageIdentity === currentPageIdentity,
  );
}

export function requiresOfficialHTMLExport(): true {
  return true;
}
