#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  closeSync,
  readFileSync,
  readSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  rmdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDirectory, "..");
const defaultDingTalkImportMaxBytes = 20 * 1024 * 1024;
const powershell = path.join(
  process.env.SystemRoot ?? "C:\\Windows",
  "System32",
  "WindowsPowerShell",
  "v1.0",
  "powershell.exe",
);

class MigrationError extends Error {
  constructor(code, message, options = {}) {
    super(message);
    this.name = "MigrationError";
    this.code = code;
    this.stage = options.stage ?? "preflight";
    this.status = options.status ?? "failed";
    this.details = options.details ?? {};
  }
}

function printHelp() {
  process.stdout.write(`Notion2DingDing 本地迁移命令

用法：
  npm run migrate -- --input <Notion ZIP或目录> (--folder <nodeId> | --workspace <workspaceId>) [选项]

必填参数：
  --input <路径>          Notion HTML 导出 ZIP 或解压目录
  --folder <nodeId>       目标钉钉文件夹 nodeId，与 --workspace 二选一
  --workspace <id>        目标钉钉知识库 ID，与 --folder 二选一

可选参数：
  --name <标题>           目标文档标题，默认从根 HTML 页面读取
  --entry <相对路径>      无法唯一推断根页面时指定 HTML 入口
  --subpages <模式>       inline（同页面展开，默认）或 tree（递归文档树）
  --output <路径>         高级/测试用途；中间 DOCX 在结束前永久删除
  --profile <profile>     固定 dws profile，所有读取和写入都使用同一值
  --force                 明确创建新文档，不复用或恢复以前的任务状态
  --dws-path <路径>       高级/测试用途，指定 dws.ps1、dws.exe 或 Node 脚本
  --help                  显示帮助
`);
}

function parseArguments(argv) {
  const options = { force: false, singlePage: false, subpages: "inline" };
  const valueOptions = new Map([
    ["--input", "input"],
    ["--folder", "folder"],
    ["--workspace", "workspace"],
    ["--name", "name"],
    ["--entry", "entry"],
    ["--subpages", "subpages"],
    ["--output", "output"],
    ["--profile", "profile"],
    ["--dws-path", "dwsPath"],
  ]);

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }
    if (argument === "--force") {
      options.force = true;
      continue;
    }
    if (argument === "--single-page") {
      options.singlePage = true;
      continue;
    }
    const property = valueOptions.get(argument);
    if (!property) {
      throw new MigrationError("ARGUMENT_ERROR", `未知参数：${argument}`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new MigrationError("ARGUMENT_ERROR", `参数 ${argument} 缺少值。`);
    }
    options[property] = value;
    index += 1;
  }
  return options;
}

function validateOptions(options) {
  if (!options.input) {
    throw new MigrationError("ARGUMENT_ERROR", "必须提供 --input。请使用 --help 查看示例。");
  }
  if (Boolean(options.folder) === Boolean(options.workspace)) {
    throw new MigrationError(
      "ARGUMENT_ERROR",
      "必须且只能提供 --folder 或 --workspace 其中一个。",
    );
  }
  if (!["inline", "tree"].includes(options.subpages)) {
    throw new MigrationError(
      "ARGUMENT_ERROR",
      "--subpages 只支持 inline 或 tree。",
    );
  }
  if (options.singlePage && options.subpages !== "inline") {
    throw new MigrationError("ARGUMENT_ERROR", "内部单页转换不能同时启用递归文档树。请移除冲突参数。");
  }
  if (options.subpages === "tree" && options.output) {
    throw new MigrationError("ARGUMENT_ERROR", "递归文档树会生成多个临时 DOCX，不支持 --output。");
  }
  if (process.platform !== "win32") {
    throw new MigrationError("PLATFORM_UNSUPPORTED", "当前 MVP 只支持 Windows 原生环境。");
  }
}

function progress(step, message) {
  process.stderr.write(`[${step}/5] ${message}\n`);
}

function hashFile(filePath) {
  const hash = createHash("sha256");
  const descriptor = openSync(filePath, "r");
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  try {
    let bytesRead;
    do {
      bytesRead = readSync(descriptor, buffer, 0, buffer.length, null);
      if (bytesRead > 0) {
        hash.update(buffer.subarray(0, bytesRead));
      }
    } while (bytesRead > 0);
  } finally {
    closeSync(descriptor);
  }
  return hash.digest("hex");
}

function listFiles(directory, root = directory) {
  const result = [];
  for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) =>
    a.name.localeCompare(b.name, "zh-CN"),
  )) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) {
      throw new MigrationError(
        "INPUT_SYMLINK_UNSUPPORTED",
        `Notion 导出目录不能包含符号链接：${path.relative(root, fullPath)}`,
      );
    }
    if (entry.isDirectory()) {
      result.push(...listFiles(fullPath, root));
    } else if (entry.isFile()) {
      result.push(fullPath);
    }
  }
  return result;
}

function fingerprintInput(inputPath) {
  const metadata = lstatSync(inputPath);
  if (metadata.isSymbolicLink()) {
    throw new MigrationError("INPUT_SYMLINK_UNSUPPORTED", "输入路径不能是符号链接。");
  }
  if (metadata.isFile()) {
    return hashFile(inputPath);
  }
  if (!metadata.isDirectory()) {
    throw new MigrationError("INPUT_TYPE_UNSUPPORTED", "输入必须是 ZIP 文件或目录。");
  }

  const hash = createHash("sha256");
  for (const file of listFiles(inputPath)) {
    const relative = path.relative(inputPath, file).replaceAll("\\", "/");
    const fileMetadata = statSync(file);
    hash.update(relative);
    hash.update("\0");
    hash.update(String(fileMetadata.size));
    hash.update("\0");
    hash.update(hashFile(file));
    hash.update("\0");
  }
  return hash.digest("hex");
}

function defaultTitle(options, inputPath) {
  const source = options.entry ? path.basename(options.entry) : path.basename(inputPath);
  return source
    .replace(/\.(zip|html|htm)$/iu, "")
    .replace(/\s+[0-9a-f]{32}$/iu, "")
    .trim() || "Notion 文档迁移";
}

function inferHtmlTitle(options, inputPath) {
  const guiScript = [
    path.join(repoRoot, "scripts", "notion2dingding-gui.ps1"),
    path.resolve(repoRoot, "..", "cli", "notion2dingding-gui.ps1"),
  ].find((candidate) => existsSync(candidate));
  if (!guiScript) {
    throw new MigrationError("HTML_TITLE_READER_MISSING", "缺少 HTML 标题识别组件。", {
      stage: "preflight",
    });
  }
  const result = runProcess(
    powershell,
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      guiScript,
      "-InferTitle",
      "-InputPath",
      inputPath,
    ],
    { label: "HTML 标题识别", stage: "preflight" },
  );
  if (result.status !== 0) {
    let message = "";
    try {
      const payload = parseJsonOutput(result.stdout, "HTML 标题识别");
      message = typeof payload?.error === "string"
        ? payload.error
        : payload?.error?.message ?? "";
    } catch {
      // 继续使用标准错误中的诊断。
    }
    throw new MigrationError(
      "HTML_INPUT_INVALID",
      message || result.stderr.trim() || "无法从 Notion HTML 导出包识别根页面标题。",
      { stage: "preflight" },
    );
  }
  const data = parseJsonOutput(result.stdout, "HTML 标题识别");
  return data.title?.trim() || defaultTitle(options, inputPath);
}

function ensureInsideRepository(targetPath, label) {
  const relative = path.relative(repoRoot, targetPath);
  if (relative.startsWith(`..${path.sep}`) || relative === ".." || path.isAbsolute(relative)) {
    throw new MigrationError("OUTPUT_OUTSIDE_REPOSITORY", `${label} 必须位于仓库目录内。`);
  }
  return relative.replaceAll("\\", "/");
}

function runProcess(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    encoding: "utf8",
    env: options.env ?? process.env,
    maxBuffer: 32 * 1024 * 1024,
    windowsHide: true,
  });
  if (result.error) {
    throw new MigrationError(
      "PROCESS_START_FAILED",
      `无法启动 ${options.label ?? command}：${result.error.message}`,
      { stage: options.stage ?? "preflight" },
    );
  }
  return {
    status: result.status ?? -1,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function parseJsonOutput(text, label) {
  const trimmed = text
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/gu, "")
    .trim();
  if (!trimmed) {
    throw new MigrationError("INVALID_JSON_OUTPUT", `${label} 没有返回 JSON。`);
  }
  try {
    return JSON.parse(trimmed);
  } catch {
    const candidates = [];
    for (let start = 0; start < trimmed.length; start += 1) {
      if (trimmed[start] !== "{" && trimmed[start] !== "[") {
        continue;
      }
      const stack = [];
      let inString = false;
      let escaped = false;
      for (let index = start; index < trimmed.length; index += 1) {
        const character = trimmed[index];
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (character === "\\") {
            escaped = true;
          } else if (character === '"') {
            inString = false;
          }
          continue;
        }
        if (character === '"') {
          inString = true;
          continue;
        }
        if (character === "{" || character === "[") {
          stack.push(character);
          continue;
        }
        if (character !== "}" && character !== "]") {
          continue;
        }
        const opening = stack.pop();
        if (
          (opening === "{" && character !== "}") ||
          (opening === "[" && character !== "]") ||
          !opening
        ) {
          break;
        }
        if (stack.length === 0) {
          try {
            candidates.push({ start, end: index, value: JSON.parse(trimmed.slice(start, index + 1)) });
          } catch {
            // 当前括号段不是 JSON，继续寻找后续候选。
          }
          break;
        }
      }
    }
    if (candidates.length > 0) {
      candidates.sort((left, right) => right.end - left.end || left.start - right.start);
      return candidates[0].value;
    }
  }
  throw new MigrationError("INVALID_JSON_OUTPUT", `${label} 返回了无法解析的 JSON。`);
}

function dingTalkImportMaxBytes() {
  const configured = Number.parseInt(process.env.N2DD_IMPORT_MAX_BYTES ?? "", 10);
  return Number.isSafeInteger(configured) && configured > 0
    ? configured
    : defaultDingTalkImportMaxBytes;
}

function formatMiB(bytes) {
  return (bytes / (1024 * 1024)).toFixed(2);
}

function resolveDwsPath(requestedPath) {
  if (requestedPath) {
    const resolved = path.resolve(requestedPath);
    if (!existsSync(resolved)) {
      throw new MigrationError("DWS_NOT_FOUND", `指定的 dws 路径不存在：${resolved}`);
    }
    return resolved;
  }

  const discovery = runProcess(
    powershell,
    ["-NoProfile", "-Command", "(Get-Command dws -ErrorAction Stop).Source"],
    { label: "dws 检测", stage: "preflight" },
  );
  const resolved = discovery.stdout.trim().split(/\r?\n/u).at(-1);
  if (discovery.status !== 0 || !resolved || !existsSync(resolved)) {
    throw new MigrationError(
      "DWS_NOT_FOUND",
      "未找到 dws。请先运行 npm install -g dingtalk-workspace-cli@1.0.59。",
    );
  }
  return resolved;
}

function dwsInvocation(dwsPath, args) {
  const extension = path.extname(dwsPath).toLowerCase();
  const npmDwsEntry = path.join(
    path.dirname(dwsPath),
    "node_modules",
    "dingtalk-workspace-cli",
    "bin",
    "dws.js",
  );
  if ([".ps1", ".cmd", ".bat"].includes(extension) && existsSync(npmDwsEntry)) {
    const bundledNode = path.join(path.dirname(dwsPath), "node.exe");
    return {
      command: existsSync(bundledNode) ? bundledNode : process.execPath,
      args: [npmDwsEntry, ...args],
    };
  }
  if (extension === ".ps1") {
    return {
      command: powershell,
      args: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", dwsPath, ...args],
    };
  }
  if (extension === ".mjs" || extension === ".js" || extension === ".cjs") {
    return { command: process.execPath, args: [dwsPath, ...args] };
  }
  if (extension === ".exe") {
    return { command: dwsPath, args };
  }
  if (extension === ".cmd" || extension === ".bat") {
    const siblingPowerShell = dwsPath.replace(/\.(cmd|bat)$/iu, ".ps1");
    if (existsSync(siblingPowerShell)) {
      return dwsInvocation(siblingPowerShell, args);
    }
  }
  throw new MigrationError(
    "DWS_LAUNCHER_UNSUPPORTED",
    `不支持的 dws 启动文件：${dwsPath}`,
  );
}

function runDws(dwsPath, args, profile, stage) {
  const finalArgs = [...args, "--format", "json"];
  if (profile) {
    finalArgs.push("--profile", profile);
  }
  const invocation = dwsInvocation(dwsPath, finalArgs);
  const result = runProcess(invocation.command, invocation.args, {
    label: "dws",
    stage,
  });
  let data;
  let parseError;
  for (const output of [result.stdout, result.stderr]) {
    if (!output.trim()) {
      continue;
    }
    try {
      data = parseJsonOutput(output, "dws");
      break;
    } catch (error) {
      parseError = error;
    }
  }
  if (data === undefined) {
    if (stage === "import") {
      throw new MigrationError(
        "IMPORT_COMMIT_UNKNOWN",
        "钉钉导入没有返回可解析的结构化回执，写入状态未知；已停止自动重试。",
        {
          stage: "import",
          status: "unknown",
          details: { reason: "invalid_import_output" },
        },
      );
    }
    if (result.status !== 0) {
      throw new MigrationError(
        "DWS_COMMAND_FAILED",
        "dws 执行失败且没有返回结构化错误。",
        { stage },
      );
    }
    throw parseError ?? new MigrationError("INVALID_JSON_OUTPUT", "dws 没有返回 JSON。");
  }
  return { ...result, data };
}

function jsonmlText(node) {
  if (typeof node === "string") {
    return node;
  }
  if (!Array.isArray(node)) {
    return "";
  }
  if (node[0] === "br") {
    return "\n";
  }
  return node.slice(2).map((child) => jsonmlText(child)).join("");
}

function collectJsonmlParagraphs(node, paragraphs = []) {
  if (!Array.isArray(node)) {
    return paragraphs;
  }
  if (node[0] === "p") {
    paragraphs.push(node);
  }
  for (const child of node.slice(2)) {
    collectJsonmlParagraphs(child, paragraphs);
  }
  return paragraphs;
}

function jsonmlAttributes(node) {
  const candidate = node?.[1];
  if (candidate && typeof candidate === "object" && !Array.isArray(candidate)) {
    return candidate;
  }
  throw new MigrationError(
    "TODO_JSONML_INVALID",
    "钉钉待办段落缺少 JSONML 属性，不能安全恢复为原生待办。",
    { stage: "todo", status: "unknown" },
  );
}

function todoParagraphKind(paragraph) {
  const attributes = jsonmlAttributes(paragraph);
  if (attributes.list?.isTaskList === true) {
    return { kind: "native", checked: attributes.list.isChecked === true };
  }
  const marker = /^\s*(?<marker>[☐☒])/u.exec(jsonmlText(paragraph))?.groups?.marker;
  if (!marker) {
    return null;
  }
  return { kind: "marker", checked: marker === "☒" };
}

function stripTodoMarker(paragraph) {
  const textReferences = [];
  const visit = (node) => {
    if (!Array.isArray(node)) {
      return;
    }
    for (let index = 2; index < node.length; index += 1) {
      const child = node[index];
      if (typeof child === "string") {
        textReferences.push({ parent: node, index });
      } else {
        visit(child);
      }
    }
  };
  visit(paragraph);
  const combined = textReferences.map(({ parent, index }) => parent[index]).join("");
  const prefix = /^\s*[☐☒]\s*/u.exec(combined)?.[0];
  if (!prefix) {
    throw new MigrationError(
      "TODO_MARKER_MISSING",
      "钉钉待办段落缺少预期方框标记，已停止修改。",
      { stage: "todo", status: "unknown" },
    );
  }
  let remaining = prefix.length;
  for (const reference of textReferences) {
    if (remaining <= 0) {
      break;
    }
    const current = reference.parent[reference.index];
    const removeCount = Math.min(remaining, current.length);
    reference.parent[reference.index] = current.slice(removeCount);
    remaining -= removeCount;
  }
}

function sanitizeTodoJsonml(node) {
  if (!Array.isArray(node)) {
    return;
  }
  const attributes = node[1];
  if (attributes && typeof attributes === "object" && !Array.isArray(attributes)) {
    delete attributes.styleId;
    if (attributes.fonts && typeof attributes.fonts === "object") {
      delete attributes.fonts.hint;
      if (Object.keys(attributes.fonts).length === 0) {
        delete attributes.fonts;
      }
    }
  }
  for (const child of node.slice(2)) {
    sanitizeTodoJsonml(child);
  }
}

function listDingTalkJsonmlBlocks(
  dwsPath,
  documentUrl,
  profile,
  stage = "todo",
  feature = "待办",
) {
  const errorPrefix = stage.toUpperCase();
  const blocks = [];
  let offset = 0;
  let totalCount;
  for (let page = 0; page < 20; page += 1) {
    const listed = runDws(
      dwsPath,
      [
        "doc",
        "block",
        "list",
        "--node",
        documentUrl,
        "--start-index",
        String(offset),
        "--end-index",
        String(offset + 50),
        "--content-format",
        "jsonml",
      ],
      profile,
      stage,
    );
    const pageBlocks = listed.data?.blocks;
    if (listed.status !== 0 || listed.data?.success !== true || !Array.isArray(pageBlocks)) {
      throw new MigrationError(
        `${errorPrefix}_BLOCK_LIST_FAILED`,
        `无法读取钉钉文档块，不能安全恢复原生${feature}。`,
        { stage, status: "unknown" },
      );
    }
    const reportedTotal = Number.parseInt(listed.data.totalCount ?? "", 10);
    if (Number.isSafeInteger(reportedTotal) && reportedTotal >= 0) {
      totalCount = reportedTotal;
      if (totalCount > 1000) {
        throw new MigrationError(
          `${errorPrefix}_BLOCK_LIMIT_EXCEEDED`,
          `钉钉文档一级块超过 1000 个，已停止${feature}恢复，避免静默截断。`,
          { stage, status: "unknown" },
        );
      }
    }
    blocks.push(...pageBlocks);
    offset += pageBlocks.length;
    if ((totalCount !== undefined && offset >= totalCount) || listed.data.hasMore !== true) {
      return blocks;
    }
    if (pageBlocks.length === 0) {
      throw new MigrationError(
        `${errorPrefix}_BLOCK_PAGINATION_STALLED`,
        `钉钉文档块分页没有前进，已停止${feature}恢复。`,
        { stage, status: "unknown" },
      );
    }
  }
  throw new MigrationError(
    `${errorPrefix}_BLOCK_LIMIT_EXCEEDED`,
    `钉钉文档块分页超过 20 页，已停止${feature}恢复。`,
    { stage, status: "unknown" },
  );
}

function parseDingTalkJsonmlTrees(blocks, stage, feature) {
  return blocks.map((block, index) => {
    if (typeof block?.jsonml !== "string" || !block.jsonml.trim()) {
      throw new MigrationError(
        `${stage.toUpperCase()}_JSONML_MISSING`,
        `钉钉返回的${feature}候选块缺少 JSONML，已停止修改。`,
        { stage, status: "unknown" },
      );
    }
    let element;
    try {
      element = JSON.parse(block.jsonml);
    } catch {
      throw new MigrationError(
        `${stage.toUpperCase()}_JSONML_INVALID`,
        `钉钉返回了无法解析的 JSONML，不能安全恢复${feature}。`,
        { stage, status: "unknown" },
      );
    }
    const attributes = element?.[1];
    const elementId = attributes && typeof attributes === "object" && !Array.isArray(attributes)
      ? attributes.uuid
      : "";
    const listedBlockId = typeof block.blockId === "string" ? block.blockId : "";
    const blockId = listedBlockId || elementId || "";
    return {
      blockId,
      element,
      index,
      idConsistent: Boolean(blockId) && Boolean(elementId) && blockId === elementId,
    };
  });
}

function collectSubpageTocCandidates(trees) {
  const headings = [];
  const links = [];
  const tocs = [];
  const visit = (node, owner) => {
    if (!Array.isArray(node)) {
      return;
    }
    const attributes = node[1];
    const validAttributes = attributes && typeof attributes === "object" &&
      !Array.isArray(attributes);
    const text = jsonmlText(node).trim();
    if (node[0] === "h2" && validAttributes && typeof attributes.uuid === "string") {
      headings.push({ node, owner, blockId: attributes.uuid, text });
    }
    if (node[0] === "toc" && validAttributes) {
      tocs.push({ node, owner, attributes });
    }
    if (node[0] === "a" && validAttributes) {
      const href = String(attributes.href ?? "").trim();
      if (href === "" || /^#n2dd-page-\d+$/u.test(href)) {
        links.push({ node, owner, kind: "legacy", text, attributes });
      }
    } else if (
      node[0] === "span" &&
      validAttributes &&
      attributes["data-type"] === "refer"
    ) {
      links.push({ node, owner, kind: "native", text, attributes });
    }
    for (const child of node.slice(2)) {
      visit(child, owner);
    }
  };
  for (const tree of trees) {
    visit(tree.element, tree);
  }
  return { headings, links, tocs };
}

function selectExactOrderedSubpageCandidates(candidates, expectedTexts, label) {
  const expectedSet = new Set(expectedTexts);
  const relevant = candidates.filter((candidate) => expectedSet.has(candidate.text));
  const actualTexts = relevant.map((candidate) => candidate.text);
  const matches = actualTexts.length === expectedTexts.length &&
    actualTexts.every((text, index) => text === expectedTexts[index]);
  if (!matches) {
    throw new MigrationError(
      "SUBPAGE_READBACK_MISMATCH",
      `钉钉导入后的${label}数量、文字或顺序与 Notion 子页面映射不一致，已停止修改。`,
      {
        stage: "subpage",
        status: "unknown",
        details: { expectedCount: expectedTexts.length, actualCount: actualTexts.length },
      },
    );
  }
  return relevant;
}

function restoreNativeSubpageToc({ dwsPath, documentUrl, profile, mapping }) {
  const targets = mapping.targets;
  const expectedLinks = mapping.links;
  if (expectedLinks.length === 0) {
    return {
      expectedPageCount: targets.length,
      expectedEntryCount: 0,
      expectedItemCount: 0,
      nativeCount: 0,
      nativeItemCount: 0,
      updatedCount: 0,
      deletedCount: 0,
      verified: targets.length === 0,
    };
  }

  let updatedCount = 0;
  let deletedCount = 0;
  const tocTitle = "子页面";
  const expectedLabels = expectedLinks.map((link) => link.label);

  const tocMatches = (toc, targetBlockIds) => {
    const content = toc?.attributes?.content;
    if (!Array.isArray(content) || content.length !== targets.length) {
      return false;
    }
    return content.every((item, index) =>
      item && typeof item === "object" && !Array.isArray(item) &&
      item.text === targets[index].title &&
      item.anchorId === targetBlockIds.get(targets[index].pageIndex) &&
      item.level === 2 &&
      Array.isArray(item.children) && item.children.length === 0
    );
  };

  const assertDedicatedEntryOwners = (links, expectedSuffix) => {
    const owners = new Set();
    for (let index = 0; index < links.length; index += 1) {
      const current = links[index];
      const expected = expectedSuffix[index];
      if (!current.owner.idConsistent) {
        throw new MigrationError(
          "SUBPAGE_BLOCK_ID_MISMATCH",
          `子页面入口“${expected.label}”所在块缺少稳定 blockId，或块 ID 与 JSONML uuid 不一致，已停止修改。`,
          { stage: "subpage", status: "unknown" },
        );
      }
      if (!["table", "p"].includes(current.owner.element?.[0])) {
        throw new MigrationError(
          "SUBPAGE_ENTRY_BLOCK_UNSAFE",
          `子页面入口“${expected.label}”不是可安全替换的独立入口块，已停止修改以避免丢失排版。`,
          { stage: "subpage", status: "unknown" },
        );
      }
      if (jsonmlText(current.owner.element).trim() !== expected.label) {
        throw new MigrationError(
          "SUBPAGE_ENTRY_BLOCK_UNSAFE",
          `子页面入口“${expected.label}”所在块还包含其他正文，已停止修改以避免丢失内容。`,
          { stage: "subpage", status: "unknown" },
        );
      }
      if (owners.has(current.owner.blockId)) {
        throw new MigrationError(
          "SUBPAGE_ENTRY_BLOCK_SHARED",
          `多个子页面入口共用同一个钉钉块，不能安全合并为目录。`,
          { stage: "subpage", status: "unknown" },
        );
      }
      owners.add(current.owner.blockId);
    }
  };

  const inspect = () => {
    const trees = parseDingTalkJsonmlTrees(
      listDingTalkJsonmlBlocks(dwsPath, documentUrl, profile, "subpage", "子页面目录"),
      "subpage",
      "子页面目录",
    );
    const candidates = collectSubpageTocCandidates(trees);
    const headings = selectExactOrderedSubpageCandidates(
      candidates.headings,
      targets.map((target) => target.title),
      "子页面目标标题",
    );
    const targetBlockIds = new Map(
      targets.map((target, index) => [target.pageIndex, headings[index].blockId]),
    );
    const relevantLinks = candidates.links.filter((candidate) =>
      expectedLabels.includes(candidate.text)
    );
    const remainingExpectedLinks = expectedLinks.slice(
      expectedLinks.length - relevantLinks.length,
    );
    const remainingMatches = relevantLinks.length <= expectedLinks.length &&
      relevantLinks.every((candidate, index) =>
        candidate.text === remainingExpectedLinks[index]?.label
      );
    if (!remainingMatches) {
      throw new MigrationError(
        "SUBPAGE_READBACK_MISMATCH",
        "钉钉导入后的子页面入口数量、文字或顺序与 Notion 映射不一致，已停止修改。",
        {
          stage: "subpage",
          status: "unknown",
          details: {
            expectedCount: expectedLinks.length,
            actualCount: relevantLinks.length,
          },
        },
      );
    }
    const relevantTocs = candidates.tocs.filter((toc) =>
      toc.attributes.title === tocTitle
    );
    if (relevantTocs.length > 1) {
      throw new MigrationError(
        "SUBPAGE_TOC_DUPLICATED",
        "钉钉文档中出现多个“子页面”目录，已停止修改，避免误删用户内容。",
        { stage: "subpage", status: "unknown" },
      );
    }
    const toc = relevantTocs[0] ?? null;
    if (toc && !tocMatches(toc, targetBlockIds)) {
      throw new MigrationError(
        "SUBPAGE_TOC_MISMATCH",
        "现有“子页面”目录的标题、顺序或锚点与本次 Notion 子页面不一致，已停止覆盖。",
        { stage: "subpage", status: "unknown" },
      );
    }
    return {
      trees,
      links: relevantLinks,
      remainingExpectedLinks,
      targetBlockIds,
      toc,
    };
  };

  try {
    let current = inspect();
    if (!current.toc) {
      if (current.links.length !== expectedLinks.length) {
        throw new MigrationError(
          "SUBPAGE_TOC_MISSING",
          "子页面目录尚未写入，但原始入口已经不完整，已停止修改并保留现有文档。",
          { stage: "subpage", status: "unknown" },
        );
      }
      assertDedicatedEntryOwners(current.links, expectedLinks);
      const owner = current.links[0].owner;
      const content = targets.map((target) => {
        const targetBlockId = current.targetBlockIds.get(target.pageIndex);
        if (!targetBlockId) {
          throw new MigrationError(
            "SUBPAGE_TARGET_BLOCK_MISSING",
            `子页面“${target.title}”没有对应的钉钉 H2 blockId，已停止修改。`,
            { stage: "subpage", status: "unknown" },
          );
        }
        return {
          uuid: `n2ddtoc${targetBlockId}`,
          anchorId: targetBlockId,
          level: 2,
          children: [],
          text: target.title,
        };
      });
      const tocElement = [
        "toc",
        {
          uuid: owner.blockId,
          title: tocTitle,
          mode: "outline",
          styles: {
            global: { maxLevel: 2, bgColor: "#FFFFFF", css: {} },
            title: { font: "", color: "#000000", numbering: false, css: {} },
            item: { symbol: "none", css: {} },
          },
          content,
        },
      ];
      const updated = runDws(
        dwsPath,
        [
          "doc",
          "block",
          "update",
          "--node",
          documentUrl,
          "--block-id",
          owner.blockId,
          "--content-format",
          "jsonml",
          "--element",
          JSON.stringify(tocElement),
        ],
        profile,
        "subpage",
      );
      const explicitlyRejected = updated.data?.success === false ||
        updated.data?.ok === false ||
        Boolean(updated.data?.error);
      if (updated.status !== 0 || explicitlyRejected) {
        throw new MigrationError(
          "SUBPAGE_TOC_UPDATE_FAILED",
          "钉钉子页面目录更新返回失败；已保留现有文档。再次执行将只恢复原文档，不会重复导入。",
          { stage: "subpage", status: "unknown" },
        );
      }
      updatedCount += 1;
      current = inspect();
    }

    assertDedicatedEntryOwners(current.links, current.remainingExpectedLinks);
    for (const link of current.links) {
      const deleted = runDws(
        dwsPath,
        [
          "doc",
          "block",
          "delete",
          "--node",
          documentUrl,
          "--block-id",
          link.owner.blockId,
          "--yes",
        ],
        profile,
        "subpage",
      );
      const explicitlyRejected = deleted.data?.success === false ||
        deleted.data?.ok === false ||
        Boolean(deleted.data?.error);
      if (deleted.status !== 0 || explicitlyRejected) {
        throw new MigrationError(
          "SUBPAGE_ENTRY_DELETE_FAILED",
          "钉钉旧子页面入口删除结果未知；已停止。再次执行将先回读，不会重复导入文档。",
          { stage: "subpage", status: "unknown" },
        );
      }
      deletedCount += 1;
    }

    const after = inspect();
    if (!after.toc || after.links.length !== 0 ||
        !tocMatches(after.toc, after.targetBlockIds)) {
      throw new MigrationError(
        "SUBPAGE_TOC_VERIFY_FAILED",
        "钉钉子页面目录更新后回读不一致，不能报告迁移成功。",
        { stage: "subpage", status: "unknown" },
      );
    }
    return {
      expectedPageCount: targets.length,
      targetCount: after.targetBlockIds.size,
      expectedEntryCount: expectedLinks.length,
      expectedItemCount: targets.length,
      nativeCount: 1,
      nativeItemCount: after.toc.attributes.content.length,
      updatedCount,
      deletedCount,
      verified: true,
    };
  } catch (error) {
    if (error instanceof MigrationError && error.status === "unknown") {
      error.details = { ...(error.details ?? {}), updatedCount, deletedCount };
      throw error;
    }
    throw new MigrationError(
      "SUBPAGE_TOC_RESTORE_FAILED",
      `恢复钉钉原生子页面目录失败：${error.message}`,
      {
        stage: "subpage",
        status: "unknown",
        details: { updatedCount, deletedCount },
      },
    );
  }
}

function collectJsonmlTableCandidates(node, tables = []) {
  if (!Array.isArray(node)) {
    return tables;
  }
  if (node[0] === "table") {
    const attributes = node[1];
    if (!attributes || typeof attributes !== "object" || Array.isArray(attributes)) {
      throw new MigrationError(
        "LAYOUT_JSONML_INVALID",
        "钉钉表格缺少 JSONML 属性，不能安全恢复为原生分栏。",
        { stage: "layout", status: "unknown" },
      );
    }
    const firstRow = node.slice(2).find((child) => Array.isArray(child) && child[0] === "tr");
    const columnCount = Array.isArray(firstRow)
      ? firstRow.slice(2).filter((child) => Array.isArray(child) && child[0] === "tc").length
      : 0;
    tables.push({
      blockId: attributes.uuid,
      columnCount,
      native: attributes.sr === true,
      styleId: typeof attributes.styleId === "string" ? attributes.styleId : "",
      element: node,
    });
  }
  for (const child of node.slice(2)) {
    collectJsonmlTableCandidates(child, tables);
  }
  return tables;
}

function findDingTalkTables(blocks) {
  const tables = [];
  const seen = new Set();
  for (const block of blocks) {
    if (typeof block?.jsonml !== "string" || !block.jsonml.trim()) {
      continue;
    }
    let tree;
    try {
      tree = JSON.parse(block.jsonml);
    } catch {
      throw new MigrationError(
        "LAYOUT_JSONML_INVALID",
        "钉钉返回了无法解析的 JSONML，不能安全恢复原生分栏。",
        { stage: "layout", status: "unknown" },
      );
    }
    for (const table of collectJsonmlTableCandidates(tree)) {
      if (typeof table.blockId !== "string" || !table.blockId) {
        throw new MigrationError(
          "LAYOUT_BLOCK_ID_MISSING",
          "钉钉表格缺少稳定 block ID，已停止修改。",
          { stage: "layout", status: "unknown" },
        );
      }
      if (table.columnCount < 1) {
        throw new MigrationError(
          "LAYOUT_COLUMN_COUNT_INVALID",
          "钉钉表格缺少可核对的首行单元格，已停止修改。",
          { stage: "layout", status: "unknown" },
        );
      }
      if (!seen.has(table.blockId)) {
        seen.add(table.blockId);
        tables.push(table);
      }
    }
  }
  return tables;
}

function makeNativeColumns(table) {
  const sanitizeListStarts = (node) => {
    if (!Array.isArray(node)) {
      return;
    }
    const nodeAttributes = node[1];
    if (
      nodeAttributes &&
      typeof nodeAttributes === "object" &&
      !Array.isArray(nodeAttributes) &&
      nodeAttributes.list &&
      typeof nodeAttributes.list === "object" &&
      typeof nodeAttributes.list.start === "number" &&
      Number.isFinite(nodeAttributes.list.start) &&
      nodeAttributes.list.start < 1
    ) {
      nodeAttributes.list.start = 1;
    }
    for (const child of node.slice(2)) {
      sanitizeListStarts(child);
    }
  };
  sanitizeListStarts(table.element);
  const attributes = table.element[1];
  attributes.sr = true;
  attributes.spacing ??= 12;
  delete attributes.bdr;
  for (const row of table.element.slice(2)) {
    if (!Array.isArray(row) || row[0] !== "tr") {
      continue;
    }
    for (const cell of row.slice(2)) {
      if (!Array.isArray(cell) || cell[0] !== "tc") {
        continue;
      }
      const cellAttributes = cell[1];
      if (cellAttributes && typeof cellAttributes === "object" && !Array.isArray(cellAttributes)) {
        delete cellAttributes.bdr;
        delete cellAttributes.fill;
        cellAttributes.vAlign ??= "top";
      }
    }
  }
  return table.element;
}

function restoreNativeLayoutBlocks({ dwsPath, documentUrl, profile, expectedSequence }) {
  const expectedLayouts = expectedSequence.filter((table) => table.kind === "layout");
  const expectedLayoutCount = expectedLayouts.length;
  if (expectedLayoutCount === 0) {
    return { expectedCount: 0, nativeCount: 0, updatedCount: 0, verified: true };
  }

  let updatedCount = 0;
  const selectVerifiedLayouts = (actual, phase) => {
    const layouts = actual.filter((table) => table.styleId.trim().toLowerCase() === "notion columns");
    const shapeMatches = layouts.length === expectedLayouts.length && layouts.every((table, index) =>
      table.columnCount === expectedLayouts[index].columnCount
    );
    const ordinaryTablesRemainData = actual.every((table) =>
      layouts.includes(table) || table.native !== true
    );
    if (!shapeMatches || !ordinaryTablesRemainData) {
      throw new MigrationError(
        "LAYOUT_READBACK_MISMATCH",
        `钉钉导入后的分栏样式或列数与 DOCX 不一致（${phase}），已停止修改，避免把普通数据表误转为分栏。`,
        { stage: "layout", status: "unknown" },
      );
    }
    return layouts;
  };

  try {
    const before = findDingTalkTables(
      listDingTalkJsonmlBlocks(dwsPath, documentUrl, profile, "layout", "分栏"),
    );
    const beforeLayouts = selectVerifiedLayouts(before, "更新前");
    for (const table of beforeLayouts) {
      if (table.native) {
        continue;
      }
      const updated = runDws(
        dwsPath,
        [
          "doc",
          "block",
          "update",
          "--node",
          documentUrl,
          "--block-id",
          table.blockId,
          "--content-format",
          "jsonml",
          "--element",
          JSON.stringify(makeNativeColumns(table)),
        ],
        profile,
        "layout",
      );
      const explicitlyRejected = updated.data?.success === false ||
        updated.data?.ok === false ||
        Boolean(updated.data?.error);
      if (updated.status !== 0 || explicitlyRejected) {
        throw new MigrationError(
          "LAYOUT_BLOCK_UPDATE_FAILED",
          "钉钉分栏更新返回失败；已保留现有文档位置。再次执行将只回读并恢复分栏，不会重复导入。",
          { stage: "layout", status: "unknown" },
        );
      }
      updatedCount += 1;
    }

    const after = findDingTalkTables(
      listDingTalkJsonmlBlocks(dwsPath, documentUrl, profile, "layout", "分栏"),
    );
    const afterLayouts = selectVerifiedLayouts(after, "更新后");
    const nativeCount = afterLayouts.filter((table) => table.native).length;
    if (nativeCount !== expectedLayoutCount) {
      throw new MigrationError(
        "LAYOUT_NATIVE_VERIFY_FAILED",
        `钉钉原生分栏回读数量不一致：实际 ${nativeCount}，预期 ${expectedLayoutCount}。`,
        { stage: "layout", status: "unknown" },
      );
    }
    return {
      expectedCount: expectedLayoutCount,
      nativeCount,
      updatedCount,
      verified: true,
    };
  } catch (error) {
    if (error instanceof MigrationError && error.status === "unknown") {
      error.details = { ...(error.details ?? {}), updatedCount };
      throw error;
    }
    throw new MigrationError(
      "LAYOUT_NATIVE_RESTORE_FAILED",
      `恢复钉钉原生分栏失败：${error.message}`,
      { stage: "layout", status: "unknown", details: { updatedCount } },
    );
  }
}

function normalizeCodeText(value) {
  return value.replace(/\r\n?/gu, "\n").replace(/\n$/u, "");
}

function normalizeCodeSyntax(value) {
  const normalized = value.trim().toLowerCase();
  if (["", "text", "plain", "plain-text", "plain_text", "none"].includes(normalized)) {
    return "plaintext";
  }
  const aliases = { js: "javascript", ts: "typescript", py: "python", ps1: "powershell" };
  return aliases[normalized] ?? normalized;
}

function collectJsonmlCodeCandidates(node, candidates = []) {
  if (!Array.isArray(node)) {
    return candidates;
  }
  const attributes = node[1];
  const validAttributes = attributes && typeof attributes === "object" &&
    !Array.isArray(attributes);
  if (node[0] === "code" && validAttributes) {
    candidates.push({
      kind: "native",
      blockId: attributes.uuid,
      syntax: normalizeCodeSyntax(String(attributes.syntax ?? "plaintext")),
      code: normalizeCodeText(String(attributes.code ?? "")),
    });
    return candidates;
  }
  if (node[0] === "p" && validAttributes && attributes.styleId === "SourceCode") {
    candidates.push({
      kind: "source",
      blockId: attributes.uuid,
      syntax: "plaintext",
      code: normalizeCodeText(jsonmlText(node)),
    });
    return candidates;
  }
  for (const child of node.slice(2)) {
    collectJsonmlCodeCandidates(child, candidates);
  }
  return candidates;
}

function findDingTalkCodeBlocks(blocks) {
  const codeBlocks = [];
  for (const block of blocks) {
    if (typeof block?.jsonml !== "string" || !block.jsonml.trim()) {
      continue;
    }
    let tree;
    try {
      tree = JSON.parse(block.jsonml);
    } catch {
      throw new MigrationError(
        "CODE_JSONML_INVALID",
        "钉钉返回了无法解析的 JSONML，不能安全恢复原生代码块。",
        { stage: "code", status: "unknown" },
      );
    }
    for (const codeBlock of collectJsonmlCodeCandidates(tree)) {
      if (typeof codeBlock.blockId !== "string" || !codeBlock.blockId) {
        throw new MigrationError(
          "CODE_BLOCK_ID_MISSING",
          "钉钉代码段落缺少稳定 block ID，已停止修改。",
          { stage: "code", status: "unknown" },
        );
      }
      codeBlocks.push(codeBlock);
    }
  }
  return codeBlocks;
}

function restoreNativeCodeBlocks({ dwsPath, documentUrl, profile, expectedBlocks }) {
  const expected = expectedBlocks.map((block) => ({
    syntax: normalizeCodeSyntax(block.syntax),
    code: normalizeCodeText(block.code),
  }));
  if (expected.length === 0) {
    return { expectedCount: 0, nativeCount: 0, updatedCount: 0, verified: true };
  }

  let updatedCount = 0;
  try {
    const before = findDingTalkCodeBlocks(
      listDingTalkJsonmlBlocks(dwsPath, documentUrl, profile, "code", "代码块"),
    );
    const contentMatches = before.length === expected.length &&
      before.every((block, index) => block.code === expected[index].code);
    if (!contentMatches) {
      throw new MigrationError(
        "CODE_READBACK_MISMATCH",
        `钉钉导入后的代码块数量或文本不一致：实际 ${before.length}，预期 ${expected.length}。`,
        { stage: "code", status: "unknown" },
      );
    }

    for (let index = 0; index < before.length; index += 1) {
      const current = before[index];
      const target = expected[index];
      if (current.kind === "native" && current.syntax === target.syntax) {
        continue;
      }
      const element = [
        "code",
        {
          uuid: current.blockId,
          syntax: target.syntax,
          code: target.code,
          wrap: true,
          showLineNumber: false,
        },
      ];
      const updated = runDws(
        dwsPath,
        [
          "doc",
          "block",
          "update",
          "--node",
          documentUrl,
          "--block-id",
          current.blockId,
          "--content-format",
          "jsonml",
          "--element",
          JSON.stringify(element),
        ],
        profile,
        "code",
      );
      const explicitlyRejected = updated.data?.success === false ||
        updated.data?.ok === false ||
        Boolean(updated.data?.error);
      if (updated.status !== 0 || explicitlyRejected) {
        throw new MigrationError(
          "CODE_BLOCK_UPDATE_FAILED",
          "钉钉代码块更新返回失败；已保留现有文档位置。再次执行将只回读并恢复代码块，不会重复导入。",
          { stage: "code", status: "unknown" },
        );
      }
      updatedCount += 1;
    }

    const after = findDingTalkCodeBlocks(
      listDingTalkJsonmlBlocks(dwsPath, documentUrl, profile, "code", "代码块"),
    );
    const verified = after.length === expected.length &&
      after.every((block, index) =>
        block.kind === "native" &&
        block.code === expected[index].code &&
        block.syntax === expected[index].syntax
      );
    if (!verified) {
      throw new MigrationError(
        "CODE_NATIVE_VERIFY_FAILED",
        "钉钉代码块更新后回读不一致，不能报告迁移成功。",
        { stage: "code", status: "unknown" },
      );
    }
    return {
      expectedCount: expected.length,
      nativeCount: after.length,
      updatedCount,
      verified: true,
    };
  } catch (error) {
    if (error instanceof MigrationError && error.status === "unknown") {
      error.details = { ...(error.details ?? {}), updatedCount };
      throw error;
    }
    throw new MigrationError(
      "CODE_NATIVE_RESTORE_FAILED",
      `恢复钉钉原生代码块失败：${error.message}`,
      { stage: "code", status: "unknown", details: { updatedCount } },
    );
  }
}

function findDingTalkTodoParagraphs(blocks) {
  const todos = [];
  for (const block of blocks) {
    if (typeof block?.jsonml !== "string" || !block.jsonml.trim()) {
      continue;
    }
    let tree;
    try {
      tree = JSON.parse(block.jsonml);
    } catch {
      throw new MigrationError(
        "TODO_JSONML_INVALID",
        "钉钉返回了无法解析的 JSONML，不能安全恢复原生待办。",
        { stage: "todo", status: "unknown" },
      );
    }
    for (const paragraph of collectJsonmlParagraphs(tree)) {
      const classification = todoParagraphKind(paragraph);
      if (!classification) {
        continue;
      }
      const blockId = jsonmlAttributes(paragraph).uuid;
      if (typeof blockId !== "string" || !blockId) {
        throw new MigrationError(
          "TODO_BLOCK_ID_MISSING",
          "钉钉待办段落缺少稳定 block ID，已停止修改。",
          { stage: "todo", status: "unknown" },
        );
      }
      todos.push({ blockId, paragraph, ...classification });
    }
  }
  return todos;
}

function restoreNativeTodoBlocks({ dwsPath, documentUrl, profile, expectedStates }) {
  const normalizedStates = expectedStates.map((state) => state === "checked");
  if (normalizedStates.length === 0) {
    return { expectedCount: 0, nativeCount: 0, updatedCount: 0, verified: true };
  }

  let updatedCount = 0;
  try {
    const before = findDingTalkTodoParagraphs(
      listDingTalkJsonmlBlocks(dwsPath, documentUrl, profile),
    );
    const statesMatch = before.length === normalizedStates.length &&
      before.every((todo, index) => todo.checked === normalizedStates[index]);
    if (!statesMatch) {
      throw new MigrationError(
        "TODO_READBACK_MISMATCH",
        `钉钉导入后的待办数量或状态不一致：实际 ${before.length}，预期 ${normalizedStates.length}。`,
        { stage: "todo", status: "unknown" },
      );
    }

    for (const todo of before) {
      if (todo.kind === "native") {
        continue;
      }
      stripTodoMarker(todo.paragraph);
      sanitizeTodoJsonml(todo.paragraph);
      const attributes = jsonmlAttributes(todo.paragraph);
      delete attributes.numPr;
      attributes.uuid = todo.blockId;
      attributes.list = {
        listId: `n2dd-${todo.blockId}`,
        level: 0,
        isOrdered: false,
        isTaskList: true,
        isChecked: todo.checked,
      };
      const updated = runDws(
        dwsPath,
        [
          "doc",
          "block",
          "update",
          "--node",
          documentUrl,
          "--block-id",
          todo.blockId,
          "--content-format",
          "jsonml",
          "--element",
          JSON.stringify(todo.paragraph),
        ],
        profile,
        "todo",
      );
      const explicitlyRejected = updated.data?.success === false ||
        updated.data?.ok === false ||
        Boolean(updated.data?.error);
      if (updated.status !== 0 || explicitlyRejected) {
        throw new MigrationError(
          "TODO_BLOCK_UPDATE_FAILED",
          "钉钉待办块更新返回失败；已保留现有文档位置。再次执行将只回读并恢复待办，不会重复导入。",
          { stage: "todo", status: "unknown" },
        );
      }
      updatedCount += 1;
    }

    const after = findDingTalkTodoParagraphs(
      listDingTalkJsonmlBlocks(dwsPath, documentUrl, profile),
    );
    const verified = after.length === normalizedStates.length &&
      after.every((todo, index) =>
        todo.kind === "native" && todo.checked === normalizedStates[index]
      );
    if (!verified) {
      throw new MigrationError(
        "TODO_NATIVE_VERIFY_FAILED",
        "钉钉待办块更新后回读不一致，不能报告迁移成功。",
        { stage: "todo", status: "unknown" },
      );
    }
    return {
      expectedCount: normalizedStates.length,
      nativeCount: after.length,
      checkedCount: normalizedStates.filter(Boolean).length,
      uncheckedCount: normalizedStates.filter((checked) => !checked).length,
      updatedCount,
      verified: true,
    };
  } catch (error) {
    if (error instanceof MigrationError && error.status === "unknown") {
      error.details = { ...(error.details ?? {}), updatedCount };
      throw error;
    }
    throw new MigrationError(
      "TODO_NATIVE_RESTORE_FAILED",
      `恢复钉钉原生待办失败：${error.message}`,
      { stage: "todo", status: "unknown", details: { updatedCount } },
    );
  }
}

function runConversion(inputPath, outputPath, entry, singlePage = false, auxiliaryDirectory = "") {
  const conversionScript = path.join(repoRoot, "scripts", "convert-notion-export.ps1");
  const command = [
    "$parameters = @{",
    "  InputPath = $env:N2DD_CONVERSION_INPUT",
    "  OutputPath = $env:N2DD_CONVERSION_OUTPUT",
    "}",
    "if (-not [string]::IsNullOrWhiteSpace($env:N2DD_CONVERSION_ENTRY)) {",
    "  $parameters.EntryPath = $env:N2DD_CONVERSION_ENTRY",
    "}",
    "if (-not [string]::IsNullOrWhiteSpace($env:N2DD_CONVERSION_AUXILIARY_DIRECTORY)) {",
    "  $parameters.AuxiliaryDirectory = $env:N2DD_CONVERSION_AUXILIARY_DIRECTORY",
    "}",
    "if ($env:N2DD_CONVERSION_SINGLE_PAGE -eq '1') {",
    "  $parameters.SinglePage = $true",
    "}",
    "& $env:N2DD_CONVERSION_SCRIPT @parameters",
    "exit $LASTEXITCODE",
  ].join("\n");
  const args = [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-Command",
    command,
  ];
  const result = runProcess(powershell, args, {
    label: "Pandoc 转换",
    stage: "convert",
    env: {
      ...process.env,
      N2DD_CONVERSION_SCRIPT: conversionScript,
      N2DD_CONVERSION_INPUT: inputPath,
      N2DD_CONVERSION_OUTPUT: outputPath,
      N2DD_CONVERSION_ENTRY: entry ?? "",
      N2DD_CONVERSION_SINGLE_PAGE: singlePage ? "1" : "0",
      N2DD_CONVERSION_AUXILIARY_DIRECTORY: auxiliaryDirectory,
    },
  });
  if (result.status !== 0) {
    let structuredMessage = "";
    try {
      structuredMessage = parseJsonOutput(result.stdout, "转换脚本")?.error?.message ?? "";
    } catch {
      // 兼容旧版转换脚本的非结构化错误输出。
    }
    const diagnostics = (result.stderr || result.stdout)
      .trim()
      .split(/\r?\n/u)
      .map((line) => line.trim())
      .filter(Boolean);
    const diagnostic =
      structuredMessage ||
      diagnostics.find((line) => /缺失|不存在|损坏|不是有效|missing|invalid|cannot/iu.test(line)) ||
      diagnostics.at(-1);
    throw new MigrationError(
      "CONVERSION_FAILED",
      diagnostic ? `本地转换失败：${diagnostic}` : "本地转换失败。",
      { stage: "convert" },
    );
  }
  const data = parseJsonOutput(result.stdout, "转换脚本");
  if (!data.success || !data.docx?.success) {
    throw new MigrationError("CONVERSION_FAILED", "转换脚本没有返回成功结果。", {
      stage: "convert",
    });
  }
  return data;
}

function runTreeManifest(inputPath, entry) {
  const conversionScript = path.join(repoRoot, "scripts", "convert-notion-export.ps1");
  const command = [
    "$parameters = @{",
    "  InputPath = $env:N2DD_CONVERSION_INPUT",
    "  ManifestOnly = $true",
    "}",
    "if (-not [string]::IsNullOrWhiteSpace($env:N2DD_CONVERSION_ENTRY)) {",
    "  $parameters.EntryPath = $env:N2DD_CONVERSION_ENTRY",
    "}",
    "& $env:N2DD_CONVERSION_SCRIPT @parameters",
    "exit $LASTEXITCODE",
  ].join("\n");
  const result = runProcess(
    powershell,
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
    {
      label: "Notion 页面树预检",
      stage: "convert",
      env: {
        ...process.env,
        N2DD_CONVERSION_SCRIPT: conversionScript,
        N2DD_CONVERSION_INPUT: inputPath,
        N2DD_CONVERSION_ENTRY: entry ?? "",
      },
    },
  );
  if (result.status !== 0) {
    let message = "";
    try {
      message = parseJsonOutput(result.stdout, "页面树预检")?.error?.message ?? "";
    } catch {
      // 使用进程诊断。
    }
    throw new MigrationError(
      "TREE_MANIFEST_FAILED",
      `无法读取 Notion 页面树：${message || result.stderr.trim() || "页面关系无效。"}`,
      { stage: "convert" },
    );
  }
  const data = parseJsonOutput(result.stdout, "页面树预检");
  if (!data.success || data.mode !== "manifest" || !Array.isArray(data.pages) ||
      data.pages.length === 0 || !Array.isArray(data.links)) {
    throw new MigrationError("TREE_MANIFEST_INVALID", "Notion 页面树预检没有返回完整页面关系。", {
      stage: "convert",
    });
  }
  return data;
}

function writeJsonAtomic(filePath, value) {
  mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.${process.pid}.tmp`;
  try {
    writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    renameSync(temporary, filePath);
  } finally {
    rmSync(temporary, { force: true });
  }
}

function readExistingState(statePath) {
  if (!existsSync(statePath)) {
    return undefined;
  }
  try {
    return JSON.parse(readFileSync(statePath, "utf8"));
  } catch {
    throw new MigrationError("STATE_CORRUPTED", `最小任务状态损坏：${statePath}`);
  }
}

function resolveStateDirectory() {
  if (process.env.N2DD_STATE_DIRECTORY) {
    return path.resolve(process.env.N2DD_STATE_DIRECTORY);
  }
  const localAppData = process.env.LOCALAPPDATA ||
    (process.env.USERPROFILE ? path.join(process.env.USERPROFILE, "AppData", "Local") : "");
  if (!localAppData) {
    throw new MigrationError(
      "STATE_DIRECTORY_UNAVAILABLE",
      "无法确定 Windows LocalAppData 目录，不能安全保存幂等状态。",
    );
  }
  return path.join(localAppData, "Notion2DingDing", "state", "migrations");
}

function ensureStateDirectoryWritable(directory) {
  mkdirSync(directory, { recursive: true });
  const probe = path.join(directory, `.write-probe-${process.pid}-${randomUUID()}`);
  try {
    writeFileSync(probe, "", { encoding: "utf8", flag: "wx" });
  } catch (error) {
    throw new MigrationError(
      "STATE_DIRECTORY_NOT_WRITABLE",
      `最小任务状态目录不可写：${error.message}`,
    );
  } finally {
    rmSync(probe, { force: true });
  }
  if (existsSync(probe)) {
    throw new MigrationError(
      "STATE_PROBE_CLEANUP_FAILED",
      "状态目录写入探针无法永久删除，已停止迁移。",
    );
  }
}

function ensureCleanupTarget(targetPath) {
  const resolved = path.resolve(targetPath);
  const relative = path.relative(repoRoot, resolved);
  if (
    relative === "" ||
    relative === ".." ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  ) {
    throw new Error(`拒绝清理仓库范围外或仓库根目录：${resolved}`);
  }
  return resolved;
}

function removeEmptyDirectory(directory) {
  if (!directory) {
    return;
  }
  try {
    rmdirSync(directory);
  } catch (error) {
    if (!["ENOENT", "ENOTEMPTY", "EEXIST"].includes(error.code)) {
      throw error;
    }
  }
}

function permanentlyDeleteOwnedContent({ taskDirectory, outputPath, temporaryRoot }) {
  const targets = [];
  if (taskDirectory) targets.push(taskDirectory);
  if (outputPath) {
    const relativeToTask = taskDirectory ? path.relative(taskDirectory, outputPath) : "..";
    const outputInsideTask = taskDirectory && relativeToTask !== ".." &&
      !relativeToTask.startsWith(`..${path.sep}`) && !path.isAbsolute(relativeToTask);
    if (!outputInsideTask) targets.push(outputPath);
  }
  const failures = [];
  for (const target of targets) {
    try {
      const resolved = ensureCleanupTarget(target);
      rmSync(resolved, {
        recursive: true,
        force: true,
        maxRetries: 3,
        retryDelay: 100,
      });
      if (existsSync(resolved)) {
        throw new Error("删除后目标仍然存在");
      }
    } catch (error) {
      failures.push({ target: path.resolve(target), message: error.message });
    }
  }
  if (taskDirectory && failures.length === 0) {
    try {
      removeEmptyDirectory(temporaryRoot);
    } catch (error) {
      failures.push({ target: path.resolve(temporaryRoot), message: error.message });
    }
  }
  return {
    success: failures.length === 0,
    permanent: true,
    verified: failures.length === 0,
    deletedTargetCount: targets.length,
    failures,
  };
}

function dwsErrorInfo(data) {
  const error = data?.error ?? {};
  return {
    category: error.category ?? error.type ?? "unknown",
    reason: error.reason ?? error.subtype ?? error.upstream_code ?? "",
    remoteStage: error.stage ?? error.details?.stage ?? "",
    remoteState: error.details?.state ?? error.details?.status ?? "",
    message: error.message ?? error.cause ?? "dws 返回未知错误。",
    taskId: error.details?.taskId ?? data?.taskId ?? "",
  };
}

function documentNodeId(documentUrl) {
  const match = /\/nodes\/([^/?#]+)/u.exec(documentUrl ?? "");
  return match?.[1] ?? "";
}

function outputResult(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function collectExternalSubpageLinkCandidates(trees) {
  const links = [];
  const visit = (node, owner) => {
    if (!Array.isArray(node)) {
      return;
    }
    const attributes = node[1];
    if (node[0] === "a" && attributes && typeof attributes === "object" &&
        !Array.isArray(attributes)) {
      links.push({
        node,
        owner,
        attributes,
        text: jsonmlText(node).trim(),
        href: String(attributes.href ?? "").trim(),
      });
    }
    for (const child of node.slice(2)) {
      visit(child, owner);
    }
  };
  for (const tree of trees) {
    visit(tree.element, tree);
  }
  return links;
}

function restoreExternalSubpageLinks({ dwsPath, documentUrl, profile, links }) {
  if (links.length === 0) {
    return { expectedCount: 0, updatedCount: 0, verified: true };
  }
  let updatedCount = 0;
  const inspect = () => {
    const trees = parseDingTalkJsonmlTrees(
      listDingTalkJsonmlBlocks(dwsPath, documentUrl, profile, "tree-links", "递归子页面链接"),
      "tree-links",
      "递归子页面链接",
    );
    const candidates = collectExternalSubpageLinkCandidates(trees);
    const selected = [];
    const usedOwners = new Set();
    let cursor = 0;
    for (const expected of links) {
      let matchIndex = -1;
      for (let index = cursor; index < candidates.length; index += 1) {
        const candidate = candidates[index];
        const isLocalOrFinal = candidate.href === expected.documentUrl ||
          !/^(?:https?:|mailto:|tel:)/iu.test(candidate.href);
        if (candidate.text === expected.label && isLocalOrFinal) {
          matchIndex = index;
          break;
        }
      }
      if (matchIndex < 0) {
        throw new MigrationError(
          "TREE_LINK_READBACK_MISMATCH",
          `没有找到可安全更新的子页面入口“${expected.label}”。`,
          { stage: "tree-links", status: "unknown" },
        );
      }
      const candidate = candidates[matchIndex];
      cursor = matchIndex + 1;
      if (!candidate.owner.idConsistent || !["table", "p"].includes(candidate.owner.element?.[0]) ||
          jsonmlText(candidate.owner.element).trim() !== expected.label ||
          usedOwners.has(candidate.owner.blockId)) {
        throw new MigrationError(
          "TREE_LINK_BLOCK_UNSAFE",
          `子页面入口“${expected.label}”与其他正文共用块，已停止修改以避免破坏排版。`,
          { stage: "tree-links", status: "unknown" },
        );
      }
      usedOwners.add(candidate.owner.blockId);
      selected.push({ candidate, expected });
    }
    return selected;
  };

  try {
    const selected = inspect();
    for (const { candidate, expected } of selected) {
      if (candidate.href === expected.documentUrl) {
        continue;
      }
      candidate.attributes.href = expected.documentUrl;
      const updated = runDws(
        dwsPath,
        [
          "doc",
          "block",
          "update",
          "--node",
          documentUrl,
          "--block-id",
          candidate.owner.blockId,
          "--content-format",
          "jsonml",
          "--element",
          JSON.stringify(candidate.owner.element),
        ],
        profile,
        "tree-links",
      );
      if (updated.status !== 0 || updated.data?.success !== true) {
        throw new MigrationError(
          "TREE_LINK_UPDATE_UNKNOWN",
          "钉钉没有明确确认子页面链接更新成功，已停止；再次执行会先回读。",
          { stage: "tree-links", status: "unknown" },
        );
      }
      updatedCount += 1;
    }
    const after = inspect();
    if (after.some(({ candidate, expected }) => candidate.href !== expected.documentUrl)) {
      throw new MigrationError(
        "TREE_LINK_VERIFY_FAILED",
        "递归子页面链接更新后的回读结果不一致。",
        { stage: "tree-links", status: "unknown" },
      );
    }
    return { expectedCount: links.length, updatedCount, verified: true };
  } catch (error) {
    if (error instanceof MigrationError) {
      error.details = { ...(error.details ?? {}), updatedCount };
      throw error;
    }
    throw new MigrationError(
      "TREE_LINK_RESTORE_FAILED",
      `恢复递归子页面链接失败：${error.message}`,
      { stage: "tree-links", status: "unknown", details: { updatedCount } },
    );
  }
}

function createdFolderId(data) {
  const directCandidates = [
    data?.data?.fileId,
    data?.data?.nodeId,
    data?.data?.id,
    data?.fileId,
    data?.nodeId,
    data?.id,
    data?.data?.folder?.fileId,
    data?.data?.folder?.nodeId,
    data?.data?.node?.nodeId,
    data?.data?.result?.fileId,
    data?.data?.result?.nodeId,
  ];
  const direct = directCandidates.find((value) => typeof value === "string" && value.trim())?.trim();
  if (direct) {
    return direct;
  }
  const visit = (value, depth = 0) => {
    if (!value || typeof value !== "object" || depth > 5) {
      return "";
    }
    for (const key of ["fileId", "nodeId"]) {
      if (typeof value[key] === "string" && value[key].trim()) {
        return value[key].trim();
      }
    }
    for (const child of Object.values(value)) {
      const found = visit(child, depth + 1);
      if (found) {
        return found;
      }
    }
    return "";
  };
  return visit(data?.data ?? data);
}

function dwsSucceeded(result) {
  return result?.status === 0 &&
    (result.data?.success === true ||
      result.data?.data?.success === true ||
      (result.data?.ok === true && result.data?.status === "success") ||
      (result.data?.ok === true && result.data?.outcome === "success"));
}

function documentStyle(result) {
  return result?.data?.data?.style ?? result?.data?.style ?? result?.data?.data?.data?.style;
}

function hasNativeCoverEvidence(style) {
  const visit = (value, key = "", depth = 0) => {
    if (depth > 6 || value === null || value === undefined) return false;
    if (/cover|resource/iu.test(key)) {
      if (typeof value === "string") return value.trim().length > 0;
      if (typeof value === "number" || typeof value === "boolean") return Boolean(value);
      if (Array.isArray(value)) return value.length > 0;
      if (typeof value === "object") return Object.keys(value).length > 0;
    }
    if (typeof value !== "object") return false;
    return Object.entries(value).some(([childKey, child]) => visit(child, childKey, depth + 1));
  };
  return visit(style);
}

function inspectNativeCover({ dwsPath, documentUrl, profile }) {
  const inspected = runDws(
    dwsPath,
    ["doc", "+inspect", "--node", documentUrl, "--include-style"],
    profile,
    "cover",
  );
  const style = documentStyle(inspected);
  return {
    commandSucceeded: dwsSucceeded(inspected),
    styleSucceeded: style?.success === true,
    coverPresent: hasNativeCoverEvidence(style),
  };
}

function restoreNativeCover({ dwsPath, documentUrl, profile, mapping, auxiliaryDirectory }) {
  if (!mapping || mapping.status === "not_present") {
    return { expectedCount: 0, nativeCount: 0, updatedCount: 0, verified: true };
  }
  if (mapping.status !== "pending_native_restore") {
    throw new MigrationError(
      "COVER_CONVERSION_AUDIT_INVALID",
      "Notion 封面没有进入可恢复的钉钉原生封面状态，已停止迁移。",
      { stage: "convert" },
    );
  }
  const fileName = typeof mapping.fileName === "string" ? mapping.fileName : "";
  if (!fileName || path.basename(fileName) !== fileName) {
    throw new MigrationError(
      "COVER_CONVERSION_AUDIT_INVALID",
      "本地转换没有返回安全的封面暂存文件名，已停止迁移。",
      { stage: "convert" },
    );
  }
  const coverPath = path.join(auxiliaryDirectory, fileName);
  const relativeCoverPath = ensureInsideRepository(coverPath, "封面暂存文件");
  if (!existsSync(coverPath) || !statSync(coverPath).isFile()) {
    throw new MigrationError(
      "COVER_TEMP_FILE_MISSING",
      "Notion 封面暂存文件不存在，已停止钉钉写入。",
      { stage: "cover", status: "unknown" },
    );
  }
  if (
    mapping.bytes !== statSync(coverPath).size ||
    mapping.sha256.toLowerCase() !== hashFile(coverPath).toLowerCase()
  ) {
    throw new MigrationError(
      "COVER_TEMP_FILE_MISMATCH",
      "Notion 封面暂存文件的大小或哈希不一致，已停止钉钉写入。",
      { stage: "cover", status: "unknown" },
    );
  }

  try {
    const before = inspectNativeCover({ dwsPath, documentUrl, profile });
    if (before.commandSucceeded && before.styleSucceeded && before.coverPresent) {
      return { expectedCount: 1, nativeCount: 1, updatedCount: 0, verified: true, reused: true };
    }
    const updated = runDws(
      dwsPath,
      ["doc", "+resource-update", "--node", documentUrl, "--file", relativeCoverPath, "--yes"],
      profile,
      "cover",
    );
    const after = inspectNativeCover({ dwsPath, documentUrl, profile });
    if (!after.commandSucceeded || !after.styleSucceeded || !after.coverPresent) {
      throw new Error("钉钉没有返回可回读确认的原生封面");
    }
    return {
      expectedCount: 1,
      nativeCount: 1,
      updatedCount: 1,
      verified: true,
      reused: false,
      writeAcknowledged: dwsSucceeded(updated),
    };
  } catch (error) {
    if (error instanceof MigrationError && error.status === "unknown") throw error;
    throw new MigrationError(
      "COVER_NATIVE_RESTORE_FAILED",
      `恢复钉钉原生封面失败：${error.message}`,
      { stage: "cover", status: "unknown" },
    );
  }
}

function workspaceNodeDetails(result) {
  const data = result?.data?.data ?? result?.data;
  return {
    workspaceId: typeof data?.workspaceId === "string" ? data.workspaceId.trim() : "",
    nodeId: typeof data?.nodeId === "string" ? data.nodeId.trim() : "",
    nodeType: typeof data?.nodeType === "string" ? data.nodeType.trim().toLowerCase() : "",
  };
}

function resolveTreeTargetContext({ dwsPath, profile, targetType, targetId }) {
  if (targetType === "workspace") {
    return { backend: "workspace", workspaceId: targetId, rootFolderId: "" };
  }

  let wikiNode;
  try {
    wikiNode = runDws(dwsPath, ["wiki", "+node-get", "--node", targetId], profile, "tree-target");
  } catch {
    wikiNode = undefined;
  }
  const wikiDetails = workspaceNodeDetails(wikiNode);
  if (dwsSucceeded(wikiNode) && wikiDetails.workspaceId && wikiDetails.nodeId === targetId &&
      wikiDetails.nodeType === "folder") {
    return {
      backend: "workspace",
      workspaceId: wikiDetails.workspaceId,
      rootFolderId: targetId,
    };
  }

  let driveNode;
  try {
    driveNode = runDws(dwsPath, ["drive", "+inspect", "--node", targetId], profile, "tree-target");
  } catch {
    driveNode = undefined;
  }
  const driveFile = driveNode?.data?.data?.data?.file ?? driveNode?.data?.data?.file;
  if (dwsSucceeded(driveNode) && driveFile?.type === "FOLDER" &&
      (driveFile.fileId === targetId || driveFile.nodeId === targetId)) {
    return { backend: "drive", workspaceId: "", rootFolderId: targetId };
  }

  throw new MigrationError(
    "TREE_TARGET_FOLDER_UNRESOLVED",
    "无法确认所选钉钉文件夹属于钉盘还是 Workspace，已在创建目录前停止。请重新选择保存位置后再试。",
    { stage: "tree-target" },
  );
}

function assertWorkspaceFolderNameAbsent({ dwsPath, profile, workspaceId, parentFolderId, name }) {
  let listed;
  try {
    listed = runDws(
      dwsPath,
      [
        "wiki",
        "+node-list",
        "--workspace",
        workspaceId,
        "--folder",
        parentFolderId,
        "--page-all",
      ],
      profile,
      "tree-folder-recovery",
    );
  } catch {
    listed = undefined;
  }
  const data = listed?.data?.data;
  if (!dwsSucceeded(listed) || data?.autoPageComplete !== true || !Array.isArray(data?.nodes)) {
    throw new MigrationError(
      "PREVIOUS_TREE_FOLDER_UNKNOWN",
      "上次创建文件夹的状态未知，且无法完整回读目标目录；禁止直接重试，以免产生重复目录。",
      { stage: "tree-folder", status: "unknown" },
    );
  }
  const matches = data.nodes.filter((node) =>
    node?.type === "folder" && node?.name === name && typeof node?.nodeId === "string"
  );
  if (matches.length > 0) {
    throw new MigrationError(
      "PREVIOUS_TREE_FOLDER_UNKNOWN",
      `目标位置已经存在同名文件夹“${name}”，无法证明它是否来自上次尝试；请人工确认后再处理。`,
      { stage: "tree-folder", status: "unknown", details: { candidateCount: matches.length } },
    );
  }
}

function createTreeFolder({ dwsPath, profile, backend, workspaceId, parentFolderId, name }) {
  const args = backend === "workspace"
    ? ["wiki", "+node-create", "--workspace", workspaceId, "--name", name, "--type", "folder"]
    : ["drive", "mkdir", "--name", name, "--folder", parentFolderId];
  if (backend === "workspace" && parentFolderId) {
    args.push("--folder", parentFolderId);
  }
  let created;
  try {
    created = runDws(dwsPath, args, profile, "tree-folder");
  } catch (error) {
    throw new MigrationError(
      "TREE_FOLDER_CREATE_UNKNOWN",
      `创建文件夹“${name}”时没有取得可确认回执，禁止直接重试。`,
      { stage: "tree-folder", status: "unknown", details: { cause: error.code ?? "DWS_ERROR" } },
    );
  }
  const acknowledged = dwsSucceeded(created);
  const folderId = createdFolderId(created.data);
  if (!acknowledged || !folderId) {
    throw new MigrationError(
      "TREE_FOLDER_CREATE_UNKNOWN",
      `钉钉没有返回可确认的文件夹 ID，无法安全继续创建“${name}”。`,
      { stage: "tree-folder", status: "unknown" },
    );
  }
  return folderId;
}

function treePageKey(inputHash, relativePath) {
  return createHash("sha256")
    .update(JSON.stringify({ inputHash, relativePath }))
    .digest("hex")
    .slice(0, 24);
}

function runTreeChildMigration({ options, inputPath, page, folderId }) {
  const args = [
    fileURLToPath(import.meta.url),
    "--input",
    inputPath,
    "--folder",
    folderId,
    "--entry",
    page.relativePath,
    "--name",
    page.title,
    "--single-page",
  ];
  if (options.profile) {
    args.push("--profile", options.profile);
  }
  if (options.dwsPath) {
    args.push("--dws-path", path.resolve(options.dwsPath));
  }
  const child = runProcess(process.execPath, args, {
    label: `页面“${page.title}”迁移`,
    stage: "tree-page",
  });
  if (child.stderr.trim()) {
    process.stderr.write(child.stderr);
  }
  let result;
  try {
    result = parseJsonOutput(child.stdout, `页面“${page.title}”迁移`);
  } catch (error) {
    throw new MigrationError(
      "TREE_PAGE_INVALID_RESPONSE",
      `页面“${page.title}”没有返回可解析的迁移结果。`,
      { stage: "tree-page", status: child.status === 0 ? "failed" : "unknown" },
    );
  }
  if (child.status !== 0 || result?.success !== true) {
    throw new MigrationError(
      result?.error?.code ?? "TREE_PAGE_MIGRATION_FAILED",
      `页面“${page.title}”迁移未完成：${result?.error?.message ?? "本地核心返回失败。"}`,
      {
        stage: result?.stage ?? "tree-page",
        status: result?.status ?? "failed",
        details: { childTaskId: result?.taskId ?? "" },
      },
    );
  }
  if (!result.remote?.documentUrl || result.cleanup?.verified !== true) {
    throw new MigrationError(
      "TREE_PAGE_RESULT_INCOMPLETE",
      `页面“${page.title}”缺少文档 URL 或清理确认。`,
      { stage: "tree-page", status: "unknown" },
    );
  }
  return result;
}

async function runTreeMigration(options) {
  const startedAt = new Date().toISOString();
  const inputCandidate = path.resolve(options.input);
  let statePath = "";
  let taskId = "";
  let inputHash = "";
  let targetType = options.folder ? "folder" : "workspace";
  let targetId = options.folder ?? options.workspace;
  let targetContext;
  let treeState;
  try {
    if (!existsSync(inputCandidate)) {
      throw new MigrationError("INPUT_NOT_FOUND", `输入路径不存在：${inputCandidate}`);
    }
    const inputPath = realpathSync.native(inputCandidate);
    inputHash = fingerprintInput(inputPath);
    const requestedName = options.name?.trim() || inferHtmlTitle(options, inputPath);
    taskId = createHash("sha256")
      .update(JSON.stringify({
        version: 9,
        mode: "tree",
        inputHash,
        entry: options.entry ?? "",
        name: requestedName,
        targetType,
        targetId,
        profile: options.profile ?? "current",
      }))
      .digest("hex")
      .slice(0, 24);
    const stateDirectory = resolveStateDirectory();
    ensureStateDirectoryWritable(stateDirectory);
    statePath = path.join(stateDirectory, `${taskId}.json`);
    const recordedState = readExistingState(statePath);
    const existing = options.force && recordedState?.status !== "cleanup_failed"
      ? undefined
      : recordedState;
    if (existing?.success && !options.force) {
      progress(5, "发现相同递归文档树迁移记录，跳过重复创建");
      outputResult({ ...existing, stateRecord: statePath, reused: true });
      return;
    }
    progress(1, "检查 Pandoc、dws、登录状态与 Notion 页面树");
    if (!existsSync(powershell)) {
      throw new MigrationError("POWERSHELL_NOT_FOUND", "未找到 Windows PowerShell 5.1。");
    }
    const dwsPath = resolveDwsPath(options.dwsPath);
    const auth = runDws(dwsPath, ["auth", "status"], options.profile, "preflight");
    if (!auth.data.authenticated || auth.data.token_valid === false) {
      throw new MigrationError(
        "DWS_NOT_AUTHENTICATED",
        "钉钉尚未登录或 Token 已失效。请先运行 dws auth login。",
      );
    }
    targetContext = resolveTreeTargetContext({
      dwsPath,
      profile: options.profile,
      targetType,
      targetId,
    });
    const manifest = runTreeManifest(inputPath, options.entry);
    const pages = manifest.pages.map((page, index) => ({
      ...page,
      title: index === 0 ? requestedName : page.title,
      pageKey: treePageKey(inputHash, page.relativePath),
    }));
    const pageByIndex = new Map(pages.map((page) => [page.pageIndex, page]));
    const pageByRelativePath = new Map(pages.map((page) => [page.relativePath, page]));
    if (pages.some((page) => !Number.isSafeInteger(page.pageIndex) || !page.title?.trim() ||
        !page.relativePath || !page.sha256)) {
      throw new MigrationError("TREE_MANIFEST_INVALID", "页面树包含无效页面信息。", { stage: "convert" });
    }
    for (const link of manifest.links) {
      if (!pageByIndex.has(link.sourcePageIndex) || !pageByIndex.has(link.targetPageIndex) ||
          !link.label?.trim()) {
        throw new MigrationError("TREE_MANIFEST_INVALID", "页面树包含无效链接关系。", { stage: "convert" });
      }
    }
    if (existing?.status === "unknown" && existing?.stage === "tree-folder") {
      const legacyDriveMisroute = !existing?.target?.backend &&
        targetType === "folder" && targetContext.backend === "workspace" &&
        Array.isArray(existing?.pages) && existing.pages.every((page) => !page?.folderId);
      if (!legacyDriveMisroute) {
        throw new MigrationError(
          "PREVIOUS_TREE_FOLDER_UNKNOWN",
          "上次创建文件夹的远端状态未知，禁止直接重试，以免产生重复目录。",
          { stage: "tree-folder", status: "unknown" },
        );
      }
      assertWorkspaceFolderNameAbsent({
        dwsPath,
        profile: options.profile,
        workspaceId: targetContext.workspaceId,
        parentFolderId: targetContext.rootFolderId,
        name: pages[0].title,
      });
      progress(1, "已确认上次把 Workspace 文件夹误按钉盘处理且目标中无同名目录；本次改用 Workspace 接口恢复");
    }

    const existingPages = options.force ? [] : (Array.isArray(existing?.pages) ? existing.pages : []);
    const persistedByKey = new Map(existingPages.map((page) => [page.pageKey, page]));
    treeState = {
      recordVersion: 3,
      success: false,
      status: "in_progress",
      stage: "tree-folder",
      taskId,
      startedAt: existing?.startedAt ?? startedAt,
      updatedAt: new Date().toISOString(),
      mode: "tree",
      source: { sha256: inputHash },
      target: {
        type: targetType,
        id: targetId,
        backend: targetContext.backend,
        workspaceId: targetContext.workspaceId,
      },
      pages: pages.map((page) => {
        const persisted = persistedByKey.get(page.pageKey);
        return {
          pageKey: page.pageKey,
          sourceSha256: page.sha256,
          parentPageKey: page.parent ? pageByRelativePath.get(page.parent)?.pageKey ?? "" : "",
          folderId: persisted?.folderId ?? "",
          status: persisted?.status ?? "pending",
          remote: persisted?.remote ?? {},
          linksVerified: persisted?.linksVerified === true,
        };
      }),
      cleanup: { success: true, permanent: true, verified: true, deletedTargetCount: 0, failures: [] },
    };
    const statePageByKey = new Map(treeState.pages.map((page) => [page.pageKey, page]));
    const saveTreeState = () => {
      treeState.updatedAt = new Date().toISOString();
      writeJsonAtomic(statePath, treeState);
    };
    saveTreeState();

    progress(2, `递归创建 ${pages.length} 个页面容器文件夹`);
    for (const page of pages) {
      const statePage = statePageByKey.get(page.pageKey);
      if (statePage.folderId) {
        continue;
      }
      const parentPage = page.parent ? pageByRelativePath.get(page.parent) : undefined;
      const parentFolderId = parentPage
        ? statePageByKey.get(parentPage.pageKey)?.folderId
        : targetContext.rootFolderId;
      if (parentPage && !parentFolderId) {
        throw new MigrationError("TREE_PARENT_FOLDER_MISSING", "父页面文件夹尚未创建，无法继续递归。", {
          stage: "tree-folder",
        });
      }
      statePage.folderId = createTreeFolder({
        dwsPath,
        profile: options.profile,
        backend: targetContext.backend,
        workspaceId: targetContext.workspaceId,
        parentFolderId,
        name: page.title,
      });
      statePage.status = "folder_created";
      saveTreeState();
    }

    progress(3, `逐页迁移 ${pages.length} 个钉钉文档`);
    const childResults = new Map();
    for (let index = 0; index < pages.length; index += 1) {
      const page = pages[index];
      const statePage = statePageByKey.get(page.pageKey);
      progress(3, `迁移页面 ${index + 1}/${pages.length}：${page.title}`);
      const child = runTreeChildMigration({
        options,
        inputPath,
        page,
        folderId: statePage.folderId,
      });
      childResults.set(page.pageKey, child);
      statePage.status = "document_created";
      statePage.remote = {
        taskId: child.remote.taskId ?? "",
        documentUrl: child.remote.documentUrl,
        nodeId: child.remote.nodeId ?? documentNodeId(child.remote.documentUrl),
      };
      saveTreeState();
    }

    progress(4, `把 ${manifest.links.length} 个 Notion 页面入口回填为钉钉文档链接`);
    let verifiedLinkCount = 0;
    for (const sourcePage of pages) {
      const sourceLinks = manifest.links
        .filter((link) => link.sourcePageIndex === sourcePage.pageIndex)
        .map((link) => ({
          label: link.label,
          documentUrl: statePageByKey.get(pageByIndex.get(link.targetPageIndex).pageKey).remote.documentUrl,
        }));
      const sourceState = statePageByKey.get(sourcePage.pageKey);
      if (sourceLinks.length > 0) {
        const audit = restoreExternalSubpageLinks({
          dwsPath,
          documentUrl: sourceState.remote.documentUrl,
          profile: options.profile,
          links: sourceLinks,
        });
        verifiedLinkCount += audit.expectedCount;
      }
      sourceState.linksVerified = true;
      sourceState.status = "success";
      saveTreeState();
    }

    const children = [...childResults.values()];
    const sumCheck = (name) => children.reduce((total, child) => total + Number(child.checks?.[name] ?? 0), 0);
    const rootPageState = statePageByKey.get(pages[0].pageKey);
    const completedAt = new Date().toISOString();
    treeState.success = true;
    treeState.status = "success";
    treeState.stage = "complete";
    treeState.completedAt = completedAt;
    treeState.remote = rootPageState.remote;
    treeState.checks = {
      expectedImageCount: sumCheck("expectedImageCount"),
      readbackImageCount: sumCheck("readbackImageCount"),
      nativeTodoCount: sumCheck("nativeTodoCount"),
      nativeCodeBlockCount: sumCheck("nativeCodeBlockCount"),
      nativeLayoutCount: sumCheck("nativeLayoutCount"),
      nativeSubpageTocItemCount: 0,
      subpageTocMatches: true,
      recursivePageCount: pages.length,
      recursiveFolderCount: pages.length,
      recursiveLinkCount: verifiedLinkCount,
      recursiveLinksMatch: verifiedLinkCount === manifest.links.length,
    };
    saveTreeState();
    progress(5, `递归文档树迁移成功：${rootPageState.remote.documentUrl}`);
    outputResult({
      ...treeState,
      source: { sha256: inputHash, inputPreserved: true },
      local: {
        docx: { count: pages.length, permanentlyDeleted: true },
        documentCount: pages.length,
        subpageCount: Math.max(0, pages.length - 1),
      },
      stateRecord: statePath,
      reused: false,
    });
  } catch (error) {
    const failure = {
      success: false,
      status: error.status ?? "failed",
      taskId,
      startedAt,
      failedAt: new Date().toISOString(),
      stage: error.stage ?? treeState?.stage ?? "tree",
      error: {
        code: error.code ?? "UNEXPECTED_ERROR",
        message: error.message,
        details: error.details ?? {},
      },
      cleanup: { success: true, permanent: true, verified: true, deletedTargetCount: 0, failures: [] },
      stateRecord: statePath,
    };
    if (treeState && statePath) {
      treeState.success = false;
      treeState.status = failure.status === "unknown" ? "unknown" : "partial";
      treeState.stage = failure.stage;
      treeState.updatedAt = failure.failedAt;
      treeState.error = { code: failure.error.code };
      try {
        writeJsonAtomic(statePath, treeState);
      } catch (stateError) {
        failure.error.details.stateWriteError = stateError.message;
      }
    }
    outputResult(failure);
    process.exitCode = 1;
  }
}

async function main() {
  let options;
  try {
    options = parseArguments(process.argv.slice(2));
    if (options.help) {
      printHelp();
      return;
    }
    validateOptions(options);
  } catch (error) {
    const failure = {
      success: false,
      status: error.status ?? "failed",
      stage: error.stage ?? "preflight",
      error: { code: error.code ?? "UNEXPECTED_ERROR", message: error.message },
    };
    outputResult(failure);
    process.exitCode = 1;
    return;
  }

  if (options.subpages === "tree") {
    await runTreeMigration(options);
    return;
  }

  const startedAt = new Date().toISOString();
  const inputCandidate = path.resolve(options.input);
  let statePath = "";
  let taskId = "";
  let inputHash = "";
  let targetType = "";
  let targetId = "";
  let outputPath = "";
  let taskDirectory = "";
  let temporaryRoot = "";
  let cleanupAttempted = false;
  let cleanupResult = {
    success: true,
    permanent: true,
    verified: true,
    deletedTargetCount: 0,
    failures: [],
  };
  let context = { stage: "preflight", remoteTaskId: "", documentUrl: "" };
  let resumableDocument;

  const performCleanup = () => {
    if (!cleanupAttempted) {
      cleanupAttempted = true;
      cleanupResult = permanentlyDeleteOwnedContent({
        taskDirectory,
        outputPath,
        temporaryRoot,
      });
    }
    return cleanupResult;
  };

  try {
    if (!existsSync(inputCandidate)) {
      throw new MigrationError("INPUT_NOT_FOUND", `输入路径不存在：${inputCandidate}`);
    }
    const inputPath = realpathSync.native(inputCandidate);
    inputHash = fingerprintInput(inputPath);
    const name = options.name?.trim() || inferHtmlTitle(options, inputPath);
    targetType = options.folder ? "folder" : "workspace";
    targetId = options.folder ?? options.workspace;
    taskId = createHash("sha256")
      .update(
        JSON.stringify({
          version: options.singlePage ? 9 : 8,
          ...(options.singlePage ? { mode: "single" } : {}),
          inputHash,
          entry: options.entry ?? "",
          name,
          targetType,
          targetId,
          profile: options.profile ?? "current",
        }),
      )
      .digest("hex")
      .slice(0, 24);

    const stateDirectory = resolveStateDirectory();
    ensureStateDirectoryWritable(stateDirectory);
    statePath = path.join(stateDirectory, `${taskId}.json`);
    const recordedState = readExistingState(statePath);
    const existing = options.force && recordedState?.status !== "cleanup_failed"
      ? undefined
      : recordedState;
    const canResumeExistingDocument =
      existing?.status === "unknown" &&
      ["cover", "layout", "subpage", "code", "todo", "readback"].includes(existing?.stage) &&
      typeof existing?.remote?.documentUrl === "string" &&
      existing.remote.documentUrl.length > 0;
    if (
      existing?.status === "cleanup_failed" ||
      (existing?.status === "unknown" && !canResumeExistingDocument)
    ) {
      throw new MigrationError(
        existing.status === "cleanup_failed"
          ? "PREVIOUS_CLEANUP_FAILED"
          : "PREVIOUS_COMMIT_UNKNOWN",
        existing.status === "cleanup_failed"
          ? "该任务上次未能完成永久清理。请先人工处理，再决定是否继续。"
          : "该任务上次写入状态未知。请先根据最小任务状态回读或人工确认，禁止直接重试。",
        { status: "unknown", stage: existing.stage ?? "import" },
      );
    }
    if (canResumeExistingDocument) {
      resumableDocument = existing;
    }
    if (existing?.success && !options.force) {
      progress(5, "发现相同输入和目标的成功记录，跳过重复写入");
      outputResult({ ...existing, stateRecord: statePath, reused: true });
      return;
    }

    temporaryRoot = path.resolve(
      process.env.N2DD_TEMP_DIRECTORY ?? path.join(repoRoot, ".n2dd-tmp"),
    );
    ensureInsideRepository(temporaryRoot, "临时任务目录");
    taskDirectory = path.join(
      temporaryRoot,
      `${taskId}-${process.pid}-${randomUUID()}`,
    );
    if (options.output) {
      outputPath = path.resolve(options.output);
      ensureInsideRepository(outputPath, "DOCX 输出路径");
      if (existsSync(outputPath)) {
        throw new MigrationError(
          "OUTPUT_ALREADY_EXISTS",
          `拒绝覆盖或删除已有文件：${outputPath}`,
        );
      }
      const outputParent = path.dirname(outputPath);
      if (!existsSync(outputParent) || !statSync(outputParent).isDirectory()) {
        throw new MigrationError(
          "OUTPUT_PARENT_NOT_FOUND",
          `--output 的父目录必须已经存在：${outputParent}`,
        );
      }
    } else {
      outputPath = path.join(taskDirectory, "document.docx");
    }
    const relativeDocx = ensureInsideRepository(outputPath, "DOCX 输出路径");

    progress(1, "检查 Pandoc、dws 与登录状态");
    if (!existsSync(powershell)) {
      throw new MigrationError("POWERSHELL_NOT_FOUND", "未找到 Windows PowerShell 5.1。");
    }
    const pandocCheck = runProcess("pandoc.exe", ["--version"], {
      label: "Pandoc",
      stage: "preflight",
    });
    if (pandocCheck.status !== 0) {
      throw new MigrationError("PANDOC_NOT_FOUND", "未找到可用的 Pandoc。请先安装 Pandoc。", {
        stage: "preflight",
      });
    }
    const dwsPath = resolveDwsPath(options.dwsPath);
    const auth = runDws(dwsPath, ["auth", "status"], options.profile, "preflight");
    if (!auth.data.authenticated || auth.data.token_valid === false) {
      throw new MigrationError(
        "DWS_NOT_AUTHENTICATED",
        "钉钉尚未登录或 Token 已失效。请先运行 dws auth login。",
        { stage: "preflight" },
      );
    }

    context.stage = "convert";
    progress(2, "预检 Notion 资源并生成自包含 DOCX");
    if (taskDirectory) {
      mkdirSync(taskDirectory, { recursive: true });
    }
    const conversion = runConversion(
      inputPath,
      outputPath,
      options.entry,
      options.singlePage,
      taskDirectory,
    );
    const imageAudit = conversion.imageAudit ?? {
      sourceReferenceCount: conversion.assetCount ?? 0,
      localizedFileCount: conversion.assetCount ?? 0,
      localizedAssetCount: conversion.assetCount ?? 0,
      hashesComplete: true,
      allReferencesResolved: true,
      outputMediaCount: conversion.docx.mediaCount ?? 0,
      outputImageOccurrenceCount: conversion.docx.imageDrawingCount ??
        conversion.docx.imageRelationshipCount ??
        0,
    };
    const imageAuditMatches =
      imageAudit.allReferencesResolved === true &&
      imageAudit.hashesComplete === true &&
      imageAudit.outputMediaCount >= imageAudit.localizedAssetCount &&
      imageAudit.outputImageOccurrenceCount >= imageAudit.sourceReferenceCount;
    if (!imageAuditMatches) {
      throw new MigrationError(
        "IMAGE_AUDIT_MISMATCH",
        "图片审计不一致，已停止钉钉写入；请检查源引用、本地化文件、哈希和 DOCX 媒体数量。",
        { stage: "convert", details: imageAudit },
      );
    }
    const subpageMapping = conversion.mappings?.subpageLinks ?? {
      detectedPageCount: 0,
      detectedLinkCount: 0,
      targets: [],
      links: [],
    };
    const expectedSubpageCount = conversion.subpageCount ?? 0;
    const subpageTargets = subpageMapping.targets;
    const expectedSubpageLinks = subpageMapping.links;
    const targetPageIndexes = new Set();
    const subpageMappingValid =
      Number.isSafeInteger(expectedSubpageCount) && expectedSubpageCount >= 0 &&
      Array.isArray(subpageTargets) &&
      Array.isArray(expectedSubpageLinks) &&
      subpageMapping.detectedPageCount === subpageTargets.length &&
      subpageMapping.detectedLinkCount === expectedSubpageLinks.length &&
      subpageTargets.length === expectedSubpageCount &&
      subpageTargets.every((target) => {
        const valid = target && Number.isSafeInteger(target.pageIndex) &&
          target.pageIndex > 0 && typeof target.title === "string" &&
          target.title.trim().length > 0 && !targetPageIndexes.has(target.pageIndex);
        if (valid) {
          targetPageIndexes.add(target.pageIndex);
        }
        return valid;
      }) &&
      expectedSubpageLinks.every((link) =>
        link && Number.isSafeInteger(link.sourcePageIndex) && link.sourcePageIndex >= 0 &&
        Number.isSafeInteger(link.targetPageIndex) &&
        targetPageIndexes.has(link.targetPageIndex) &&
        typeof link.label === "string" && link.label.trim().length > 0 &&
        typeof link.targetTitle === "string" &&
        link.targetTitle === subpageTargets.find((target) =>
          target.pageIndex === link.targetPageIndex
        )?.title
      );
    if (!subpageMappingValid || (expectedSubpageCount > 0 && expectedSubpageLinks.length === 0)) {
      throw new MigrationError(
        "SUBPAGE_CONVERSION_AUDIT_INVALID",
        "本地转换没有返回可核对的子页面入口与目标章节映射，已停止钉钉写入。",
        { stage: "convert" },
      );
    }
    let subpageAudit = {
      expectedPageCount: subpageTargets.length,
      targetCount: 0,
      expectedEntryCount: expectedSubpageLinks.length,
      expectedItemCount: subpageTargets.length,
      nativeCount: 0,
      nativeItemCount: 0,
      updatedCount: 0,
      deletedCount: 0,
      verified: expectedSubpageLinks.length === 0,
    };
    const importLimitBytes = dingTalkImportMaxBytes();
    if (!resumableDocument && conversion.docx.bytes > importLimitBytes) {
      throw new MigrationError(
        "IMPORT_FILE_TOO_LARGE",
        `生成的 DOCX 为 ${formatMiB(conversion.docx.bytes)} MiB，超过钉钉 ${formatMiB(importLimitBytes)} MiB 的导入上限；已在写入前停止。请减少图片体积或拆分页面后重试。`,
        {
          stage: "convert",
          details: {
            docxBytes: conversion.docx.bytes,
            importLimitBytes,
            optimizedAssetCount: imageAudit.optimizedAssetCount ?? 0,
          },
        },
      );
    }

    const expectedTodoStates = conversion.mappings?.todo?.stateSequence ?? [];
    if (!Array.isArray(expectedTodoStates) ||
        expectedTodoStates.some((state) => !["checked", "unchecked"].includes(state))) {
      throw new MigrationError(
        "TODO_CONVERSION_AUDIT_INVALID",
        "本地转换没有返回可核对的待办状态，已停止钉钉写入。",
        { stage: "convert" },
      );
    }
    let todoAudit = {
      expectedCount: expectedTodoStates.length,
      nativeCount: 0,
      updatedCount: 0,
      verified: expectedTodoStates.length === 0,
    };
    const expectedCodeBlocks = conversion.mappings?.code?.blocks ?? [];
    if (!Array.isArray(expectedCodeBlocks) || expectedCodeBlocks.some((block) =>
      !block || typeof block.code !== "string" || typeof block.syntax !== "string" ||
      !block.syntax.trim()
    )) {
      throw new MigrationError(
        "CODE_CONVERSION_AUDIT_INVALID",
        "本地转换没有返回可核对的代码块文本与语言，已停止钉钉写入。",
        { stage: "convert" },
      );
    }
    let codeAudit = {
      expectedCount: expectedCodeBlocks.length,
      nativeCount: 0,
      updatedCount: 0,
      verified: expectedCodeBlocks.length === 0,
    };
    const expectedTableSequence = conversion.mappings?.columns?.tableSequence ?? [];
    const expectedLayoutCount = conversion.mappings?.columns?.multiColumnListCount ?? 0;
    if (!Array.isArray(expectedTableSequence) || expectedTableSequence.some((table) =>
      !table || !["layout", "data"].includes(table.kind) ||
      !Number.isSafeInteger(table.columnCount) || table.columnCount < 1
    ) || expectedTableSequence.filter((table) => table.kind === "layout").length !== expectedLayoutCount) {
      throw new MigrationError(
        "LAYOUT_CONVERSION_AUDIT_INVALID",
        "本地转换没有返回可核对的表格顺序、类型和列数，已停止钉钉写入。",
        { stage: "convert" },
      );
    }
    let layoutAudit = {
      expectedCount: expectedLayoutCount,
      nativeCount: 0,
      updatedCount: 0,
      verified: expectedLayoutCount === 0,
    };
    const coverMapping = conversion.mappings?.cover ?? {
      detectedCount: 0,
      status: "not_present",
      fileName: "",
      sha256: "",
      bytes: 0,
    };
    const coverMappingValid =
      Number.isSafeInteger(coverMapping.detectedCount) &&
      coverMapping.detectedCount >= 0 && coverMapping.detectedCount <= 1 &&
      ((coverMapping.detectedCount === 0 && coverMapping.status === "not_present") ||
        (coverMapping.detectedCount === 1 && coverMapping.status === "pending_native_restore" &&
          typeof coverMapping.fileName === "string" && coverMapping.fileName.length > 0 &&
          typeof coverMapping.sha256 === "string" && /^[0-9a-f]{64}$/iu.test(coverMapping.sha256) &&
          Number.isSafeInteger(coverMapping.bytes) && coverMapping.bytes > 0));
    if (!coverMappingValid) {
      throw new MigrationError(
        "COVER_CONVERSION_AUDIT_INVALID",
        "本地转换没有返回可核对的根页面封面映射，已停止钉钉写入。",
        { stage: "convert" },
      );
    }
    let coverAudit = {
      expectedCount: coverMapping.detectedCount,
      nativeCount: 0,
      updatedCount: 0,
      verified: coverMapping.detectedCount === 0,
    };

    let documentType = resumableDocument?.remote?.documentType ?? "";
    if (resumableDocument) {
      context.remoteTaskId = resumableDocument.remote?.taskId ?? "";
      context.documentUrl = resumableDocument.remote.documentUrl;
      progress(
        3,
        ["cover", "layout", "subpage", "code", "todo"].includes(resumableDocument.stage)
          ? "发现上次已导入文档，仅恢复原生封面、分栏、子页面目录、块和回读，不重复导入"
          : "发现上次已写入文档，仅恢复回读，不重复导入",
      );
    } else {
      context.stage = "import";
      progress(3, "导入钉钉在线文档");
      const importArgs = [
        "doc",
        "+import",
        "--file",
        relativeDocx,
        options.folder ? "--folder" : "--workspace",
        targetId,
        "--name",
        name,
      ];
      const imported = runDws(dwsPath, importArgs, options.profile, "import");
      if (imported.status !== 0 || !imported.data.success) {
        const info = dwsErrorInfo(imported.data);
        context.remoteTaskId = info.taskId;
        const unknown =
          info.reason === "doc_write_commit_unknown" ||
          info.remoteState === "unknown" ||
          imported.data?.status === "unknown";
        if (unknown) {
          throw new MigrationError(
            "IMPORT_COMMIT_UNKNOWN",
            "钉钉文档写入状态未知；已停止，禁止自动重试。请使用任务记录中的信息先确认服务端状态。",
            { stage: "import", status: "unknown", details: info },
          );
        }
        const permission = /auth|permission|forbidden|denied/iu.test(
          `${info.category} ${info.reason} ${info.message}`,
        );
        throw new MigrationError(
          permission ? "IMPORT_PERMISSION_DENIED" : "IMPORT_FAILED",
          permission ? `钉钉目标无写入权限：${info.message}` : `钉钉导入失败：${info.message}`,
          { stage: "import", details: info },
        );
      }

      context.remoteTaskId = imported.data.taskId ?? "";
      context.documentUrl = imported.data.documentUrl ?? "";
      documentType = imported.data.documentType ?? "";
      if (!context.remoteTaskId || !context.documentUrl) {
        throw new MigrationError(
          "IMPORT_RESULT_INCOMPLETE",
          "钉钉导入返回成功，但缺少 taskId 或 documentUrl；不能报告迁移成功。",
          { stage: "import", status: "unknown" },
        );
      }
    }

    if (coverMapping.detectedCount > 0) {
      context.stage = "cover";
      progress(4, "把 Notion 根页面封面恢复为钉钉原生文档封面");
      coverAudit = restoreNativeCover({
        dwsPath,
        documentUrl: context.documentUrl,
        profile: options.profile,
        mapping: coverMapping,
        auxiliaryDirectory: taskDirectory,
      });
    }

    if (expectedLayoutCount > 0) {
      context.stage = "layout";
      progress(4, `把 ${expectedLayoutCount} 个布局表恢复为钉钉原生分栏并核对普通表格`);
      layoutAudit = restoreNativeLayoutBlocks({
        dwsPath,
        documentUrl: context.documentUrl,
        profile: options.profile,
        expectedSequence: expectedTableSequence,
      });
    }

    if (expectedSubpageLinks.length > 0) {
      context.stage = "subpage";
      progress(4, `生成包含 ${subpageTargets.length} 个二级标题的钉钉原生子页面目录`);
      subpageAudit = restoreNativeSubpageToc({
        dwsPath,
        documentUrl: context.documentUrl,
        profile: options.profile,
        mapping: { targets: subpageTargets, links: expectedSubpageLinks },
      });
    }

    if (expectedCodeBlocks.length > 0) {
      context.stage = "code";
      progress(4, `恢复 ${expectedCodeBlocks.length} 个钉钉原生代码块并核对文本与语言`);
      codeAudit = restoreNativeCodeBlocks({
        dwsPath,
        documentUrl: context.documentUrl,
        profile: options.profile,
        expectedBlocks: expectedCodeBlocks,
      });
    }

    if (expectedTodoStates.length > 0) {
      context.stage = "todo";
      progress(4, `恢复 ${expectedTodoStates.length} 个钉钉原生待办并核对勾选状态`);
      todoAudit = restoreNativeTodoBlocks({
        dwsPath,
        documentUrl: context.documentUrl,
        profile: options.profile,
        expectedStates: expectedTodoStates,
      });
    }

    context.stage = "readback";
    progress(4, "使用真实文档 URL 回读验证");
    const fetched = runDws(
      dwsPath,
      ["doc", "+fetch", "--node", context.documentUrl],
      options.profile,
      "readback",
    );
    const content = fetched.data?.content;
    if (
      fetched.status !== 0 ||
      fetched.data?.status !== "success" ||
      fetched.data?.complete !== true ||
      content?.success !== true
    ) {
      throw new MigrationError(
        "READBACK_FAILED",
        "钉钉返回了文档链接，但回读验证失败；不能报告迁移成功。",
        { stage: "readback", status: "unknown" },
      );
    }

    const markdown = content.markdown ?? "";
    const imageMarkers = [
      ...markdown.matchAll(/!\[[^\]]*\]\((?<url>[^)]+)\)/gu),
    ];
    const readbackImageCount = imageMarkers.filter(
      (match) => !/^data:/iu.test(match.groups?.url?.trim() ?? ""),
    ).length;
    const ignoredInlineImageCount = imageMarkers.length - readbackImageCount;
    const expectedImageCount =
      imageAudit.sourceReferenceCount ??
      conversion.docx.mediaCount ??
      conversion.assetCount ??
      0;
    const titleMatches = content.title === name;
    const escapedName = name.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
    const titleCollision = new RegExp(
      `^${escapedName}\\s*\\((?<index>\\d+)\\)$`,
      "u",
    ).exec(content.title ?? "");
    const titleCollisionIndex = Number.parseInt(
      titleCollision?.groups?.index ?? "0",
      10,
    );
    const titleAdjusted =
      Number.isSafeInteger(titleCollisionIndex) && titleCollisionIndex > 0;
    const titleAccepted = titleMatches || titleAdjusted;
    const bodyPresent = markdown.trim().length > 0;
    const imagesMatch = readbackImageCount >= expectedImageCount;
    if (!titleAccepted || !bodyPresent || !imagesMatch) {
      throw new MigrationError(
        "READBACK_MISMATCH",
        `回读内容不完整：标题=${titleAccepted}（精确=${titleMatches}），正文=${bodyPresent}，图片=${readbackImageCount}/${expectedImageCount}。`,
        { stage: "readback", status: "unknown" },
      );
    }

    context.stage = "complete";
    const completedAt = new Date().toISOString();
    const cleanupAudit = performCleanup();
    if (!cleanupAudit.success) {
      throw new MigrationError(
        "CLEANUP_FAILED",
        "钉钉文档已通过回读，但本地中间数据未能全部永久删除，不能报告成功。",
        {
          stage: "cleanup",
          status: "cleanup_failed",
          details: { failures: cleanupAudit.failures },
        },
      );
    }
    const remote = {
      taskId: context.remoteTaskId,
      documentUrl: context.documentUrl,
      nodeId: content.nodeId || documentNodeId(context.documentUrl),
      documentType,
    };
    const checks = {
      titleMatches,
      titleAccepted,
      titleAdjusted,
      titleCollisionIndex,
      bodyPresent,
      expectedImageCount,
      readbackImageCount,
      totalImageMarkerCount: imageMarkers.length,
      ignoredInlineImageCount,
      imagesMatch,
      imageAuditMatches,
      expectedCoverCount: coverAudit.expectedCount,
      nativeCoverCount: coverAudit.nativeCount,
      coverMatches: coverAudit.verified,
      expectedSubpageCount: subpageTargets.length,
      expectedSubpageEntryCount: expectedSubpageLinks.length,
      nativeSubpageTocCount: subpageAudit.nativeCount,
      nativeSubpageTocItemCount: subpageAudit.nativeItemCount,
      subpageTocMatches: subpageAudit.verified,
      expectedTodoCount: expectedTodoStates.length,
      nativeTodoCount: todoAudit.nativeCount,
      todosMatch: todoAudit.verified,
      expectedCodeBlockCount: expectedCodeBlocks.length,
      nativeCodeBlockCount: codeAudit.nativeCount,
      codeBlocksMatch: codeAudit.verified,
      nativeLayoutCount: layoutAudit.nativeCount,
      layoutsMatch: layoutAudit.verified,
      resumedReadback: Boolean(resumableDocument),
      resumedStage: resumableDocument?.stage ?? "",
    };
    const state = {
      recordVersion: 2,
      success: true,
      status: "success",
      taskId,
      startedAt,
      completedAt,
      source: { sha256: inputHash },
      target: { type: targetType, id: targetId },
      remote,
      checks,
      cleanup: cleanupAudit,
    };
    writeJsonAtomic(statePath, state);
    const result = {
      ...state,
      source: {
        sha256: inputHash,
        inputPreserved: true,
      },
      local: {
        docx: {
          sha256: conversion.docx.sha256,
          bytes: conversion.docx.bytes,
          permanentlyDeleted: true,
        },
        assetCount: conversion.assetCount,
        documentCount: conversion.documentCount ?? 1,
        subpageCount: conversion.subpageCount ?? 0,
        sourceCharacters: conversion.sourceCharacters ?? 0,
        documents: conversion.documents ?? [],
        imageAudit,
        assets: conversion.assets ?? [],
        mappings: {
          ...(conversion.mappings ?? {}),
          subpageLinks: {
            ...(conversion.mappings?.subpageLinks ?? {}),
            status: expectedSubpageLinks.length > 0 ? "preserved" : "not_present",
            output: expectedSubpageLinks.length > 0
              ? "钉钉原生子页面目录（精确 H2 锚点）"
              : "无子页面入口",
            nativeRestore: subpageAudit,
          },
          todo: {
            ...(conversion.mappings?.todo ?? {}),
            status: expectedTodoStates.length > 0 ? "preserved" : "not_present",
            output: expectedTodoStates.length > 0 ? "钉钉原生可点击待办" : "无待办",
            nativeRestore: todoAudit,
          },
          code: {
            detectedCount: expectedCodeBlocks.length,
            docxSourceCodeCount: conversion.mappings?.code?.docxSourceCodeCount ?? 0,
            status: expectedCodeBlocks.length > 0 ? "preserved" : "not_present",
            output: expectedCodeBlocks.length > 0 ? "钉钉原生代码块" : "无代码块",
            nativeRestore: codeAudit,
          },
          columns: {
            ...(conversion.mappings?.columns ?? {}),
            status: expectedLayoutCount > 0 ? "preserved" : conversion.mappings?.columns?.status,
            output: expectedLayoutCount > 0 ? "钉钉原生分栏（sr:true）" : conversion.mappings?.columns?.output,
            nativeRestore: layoutAudit,
          },
          cover: {
            detectedCount: coverMapping.detectedCount,
            status: coverMapping.detectedCount > 0 ? "preserved" : "not_present",
            output: coverMapping.detectedCount > 0 ? "钉钉原生文档封面" : "无封面",
            nativeRestore: coverAudit,
          },
        },
        warnings: conversion.warnings ?? [],
      },
      stateRecord: statePath,
      reused: false,
    };
    progress(5, `迁移成功：${context.documentUrl}`);
    outputResult(result);
  } catch (error) {
    const cleanupAudit = performCleanup();
    const effectiveError = cleanupAudit.success
      ? error
      : new MigrationError(
        "CLEANUP_FAILED",
        "本地中间数据未能全部永久删除；已停止并返回待人工处理的准确路径。",
        {
          stage: "cleanup",
          status: "cleanup_failed",
          details: {
            originalError: {
              code: error.code ?? "UNEXPECTED_ERROR",
              stage: error.stage ?? context.stage,
              status: error.status ?? "failed",
            },
            failures: cleanupAudit.failures,
          },
        },
      );
    const failure = {
      success: false,
      status: effectiveError.status ?? "failed",
      taskId,
      startedAt,
      failedAt: new Date().toISOString(),
      stage: effectiveError.stage ?? context.stage,
      remoteTaskId: context.remoteTaskId,
      documentUrl: context.documentUrl,
      error: {
        code: effectiveError.code ?? "UNEXPECTED_ERROR",
        message: effectiveError.message,
        details: effectiveError.details ?? {},
      },
      cleanup: cleanupAudit,
      stateRecord: statePath,
    };
    const previousStateError = [
      "PREVIOUS_COMMIT_UNKNOWN",
      "PREVIOUS_CLEANUP_FAILED",
    ].includes(effectiveError.code);
    const shouldPersistState =
      !previousStateError &&
      Boolean(statePath) &&
      (["unknown", "cleanup_failed"].includes(failure.status) ||
        Boolean(context.documentUrl));
    if (shouldPersistState) {
      const minimalState = {
        recordVersion: 1,
        success: false,
        status: failure.status,
        taskId,
        startedAt,
        updatedAt: failure.failedAt,
        stage: failure.stage,
        source: { sha256: inputHash },
        target: { type: targetType, id: targetId },
        remote: {
          taskId: context.remoteTaskId,
          documentUrl: context.documentUrl,
          nodeId: documentNodeId(context.documentUrl),
        },
        error: { code: failure.error.code },
        cleanup: cleanupAudit,
      };
      try {
        writeJsonAtomic(statePath, minimalState);
      } catch (stateError) {
        failure.error.details.stateWriteError = stateError.message;
        failure.stateRecord = "";
      }
    }
    outputResult(failure);
    process.exitCode = 1;
  }
}

await main();
