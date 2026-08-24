#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
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
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDirectory, "..");
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
  --input <路径>          Notion Markdown & CSV 导出 ZIP 或解压目录
  --folder <nodeId>       目标钉钉文件夹 nodeId，与 --workspace 二选一
  --workspace <id>        目标钉钉知识库 ID，与 --folder 二选一

可选参数：
  --name <标题>           目标文档标题，默认从入口 Markdown 文件名推导
  --entry <相对路径>      导出包含多个 Markdown 时指定入口
  --output <路径>         中间 DOCX；必须位于仓库目录内
  --profile <profile>     固定 dws profile，所有读取和写入都使用同一值
  --force                 已有成功记录时明确创建新文档；未知状态仍禁止重试
  --dws-path <路径>       高级/测试用途，指定 dws.ps1、dws.exe 或 Node 脚本
  --help                  显示帮助
`);
}

function parseArguments(argv) {
  const options = { force: false };
  const valueOptions = new Map([
    ["--input", "input"],
    ["--folder", "folder"],
    ["--workspace", "workspace"],
    ["--name", "name"],
    ["--entry", "entry"],
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
    .replace(/\.(zip|md|markdown)$/iu, "")
    .replace(/\s+[0-9a-f]{32}$/iu, "")
    .trim() || "Notion 文档迁移";
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
  const trimmed = text.trim();
  if (!trimmed) {
    throw new MigrationError("INVALID_JSON_OUTPUT", `${label} 没有返回 JSON。`);
  }
  try {
    return JSON.parse(trimmed);
  } catch {
    for (let index = trimmed.indexOf("{"); index >= 0; index = trimmed.indexOf("{", index + 1)) {
      try {
        return JSON.parse(trimmed.slice(index));
      } catch {
        // 继续寻找下一段可能的 JSON 起点。
      }
    }
  }
  throw new MigrationError("INVALID_JSON_OUTPUT", `${label} 返回了无法解析的 JSON。`);
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
  try {
    data = parseJsonOutput(result.stdout, "dws");
  } catch (error) {
    const diagnostic = (result.stderr || result.stdout).trim().split(/\r?\n/u).at(-1);
    if (stage === "import") {
      throw new MigrationError(
        "IMPORT_COMMIT_UNKNOWN",
        diagnostic
          ? `钉钉导入没有返回可确认的 JSON，写入状态未知：${diagnostic}`
          : "钉钉导入没有返回可确认的 JSON，写入状态未知。",
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
        diagnostic ? `dws 执行失败：${diagnostic}` : "dws 执行失败且没有返回结构化错误。",
        { stage },
      );
    }
    throw error;
  }
  return { ...result, data };
}

function runConversion(inputPath, outputPath, entry) {
  const conversionScript = path.join(repoRoot, "scripts", "convert-notion-export.ps1");
  const args = [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    conversionScript,
    "-InputPath",
    inputPath,
    "-OutputPath",
    outputPath,
  ];
  if (entry) {
    args.push("-EntryPath", entry);
  }
  const result = runProcess(powershell, args, { label: "Pandoc 转换", stage: "convert" });
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

function writeJsonAtomic(filePath, value) {
  mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  renameSync(temporary, filePath);
}

function readExistingReport(reportPath) {
  if (!existsSync(reportPath)) {
    return undefined;
  }
  try {
    return JSON.parse(readFileSync(reportPath, "utf8"));
  } catch {
    throw new MigrationError("REPORT_CORRUPTED", `任务记录损坏：${reportPath}`);
  }
}

function dwsErrorInfo(data) {
  const error = data?.error ?? {};
  return {
    category: error.category ?? "unknown",
    reason: error.reason ?? "",
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

  const startedAt = new Date().toISOString();
  const inputCandidate = path.resolve(options.input);
  let reportPath;
  let taskId;
  let context = { stage: "preflight", remoteTaskId: "", documentUrl: "" };

  try {
    if (!existsSync(inputCandidate)) {
      throw new MigrationError("INPUT_NOT_FOUND", `输入路径不存在：${inputCandidate}`);
    }
    const inputPath = realpathSync.native(inputCandidate);
    const inputHash = fingerprintInput(inputPath);
    const name = options.name?.trim() || defaultTitle(options, inputPath);
    const targetType = options.folder ? "folder" : "workspace";
    const targetId = options.folder ?? options.workspace;
    taskId = createHash("sha256")
      .update(
        JSON.stringify({
          version: 1,
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

    const artifactDirectory = path.join(repoRoot, "artifacts", "migrations");
    reportPath = path.join(artifactDirectory, `${taskId}.json`);
    const existing = readExistingReport(reportPath);
    if (existing?.status === "unknown") {
      throw new MigrationError(
        "PREVIOUS_COMMIT_UNKNOWN",
        "该任务上次写入状态未知。请先根据任务记录回读或人工确认，禁止直接重试。",
        { status: "unknown", stage: existing.stage ?? "import" },
      );
    }
    if (existing?.success && !options.force) {
      progress(5, "发现相同输入和目标的成功记录，跳过重复写入");
      outputResult({ ...existing, reused: true });
      return;
    }

    const outputPath = path.resolve(
      options.output ?? path.join(artifactDirectory, `${taskId}.docx`),
    );
    const relativeDocx = ensureInsideRepository(outputPath, "DOCX 输出路径");
    mkdirSync(path.dirname(outputPath), { recursive: true });

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
    const conversion = runConversion(inputPath, outputPath, options.entry);

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
    if (!context.remoteTaskId || !context.documentUrl) {
      throw new MigrationError(
        "IMPORT_RESULT_INCOMPLETE",
        "钉钉导入返回成功，但缺少 taskId 或 documentUrl；不能报告迁移成功。",
        { stage: "import", status: "unknown" },
      );
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
    const readbackImageCount = (markdown.match(/!\[[^\]]*\]\(/gu) ?? []).length;
    const expectedImageCount = conversion.docx.mediaCount ?? conversion.assetCount ?? 0;
    const titleMatches = content.title === name;
    const bodyPresent = markdown.trim().length > 0;
    const imagesMatch = readbackImageCount >= expectedImageCount;
    if (!titleMatches || !bodyPresent || !imagesMatch) {
      throw new MigrationError(
        "READBACK_MISMATCH",
        `回读内容不完整：标题=${titleMatches}，正文=${bodyPresent}，图片=${readbackImageCount}/${expectedImageCount}。`,
        { stage: "readback", status: "unknown" },
      );
    }

    context.stage = "complete";
    const result = {
      success: true,
      status: "success",
      taskId,
      startedAt,
      completedAt: new Date().toISOString(),
      source: {
        input: inputPath,
        sha256: inputHash,
        entry: conversion.entry,
      },
      target: { type: targetType, id: targetId },
      local: {
        docx: outputPath,
        sha256: conversion.docx.sha256,
        bytes: conversion.docx.bytes,
        assetCount: conversion.assetCount,
      },
      remote: {
        taskId: context.remoteTaskId,
        documentUrl: context.documentUrl,
        nodeId: content.nodeId || documentNodeId(context.documentUrl),
        title: content.title,
        documentType: imported.data.documentType ?? "",
      },
      checks: {
        titleMatches,
        bodyPresent,
        expectedImageCount,
        readbackImageCount,
        imagesMatch,
      },
      report: reportPath,
      reused: false,
    };
    writeJsonAtomic(reportPath, result);
    progress(5, `迁移成功：${context.documentUrl}`);
    outputResult(result);
  } catch (error) {
    const failure = {
      success: false,
      status: error.status ?? "failed",
      taskId: taskId ?? "",
      startedAt,
      failedAt: new Date().toISOString(),
      stage: error.stage ?? context.stage,
      remoteTaskId: context.remoteTaskId,
      documentUrl: context.documentUrl,
      error: {
        code: error.code ?? "UNEXPECTED_ERROR",
        message: error.message,
        details: error.details ?? {},
      },
      report: reportPath ?? "",
    };
    if (reportPath) {
      writeJsonAtomic(reportPath, failure);
    }
    outputResult(failure);
    process.exitCode = 1;
  }
}

await main();
