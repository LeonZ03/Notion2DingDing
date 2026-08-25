#!/usr/bin/env node

import { appendFileSync, copyFileSync, existsSync, readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";

const args = process.argv.slice(2);
const scenario = process.env.N2DD_FAKE_SCENARIO ?? "success";
const logPath = process.env.N2DD_FAKE_LOG;
const requestedImageCount = Number.parseInt(process.env.N2DD_FAKE_IMAGE_COUNT ?? "2", 10);
const fakeImageCount = Number.isSafeInteger(requestedImageCount) && requestedImageCount >= 0
  ? requestedImageCount
  : 2;

function option(name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

function logCall() {
  if (!logPath) {
    return;
  }
  appendFileSync(
    logPath,
    `${JSON.stringify({ args, scenario, name: option("--name") ?? "" })}\n`,
    "utf8",
  );
}

function lastImportedName() {
  if (!logPath || !existsSync(logPath)) {
    return "阶段 2 自动验收";
  }
  const records = readFileSync(logPath, "utf8")
    .trim()
    .split(/\r?\n/u)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  return [...records].reverse().find((record) => record.args?.includes("+import"))?.name ||
    "阶段 2 自动验收";
}

function output(value, status = 0) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
  process.exitCode = status;
}

logCall();

if (args[0] === "auth" && args[1] === "status") {
  if (scenario === "unauthenticated") {
    output({ success: true, authenticated: false, token_valid: false });
  } else {
    output({ success: true, authenticated: true, token_valid: true });
  }
} else if (args[0] === "doc" && args[1] === "+import") {
  const capturePath = process.env.N2DD_FAKE_CAPTURE_DOCX;
  if (capturePath) {
    copyFileSync(path.resolve(option("--file")), path.resolve(capturePath));
  }
  if (scenario === "malformed-import") {
    process.stdout.write("服务端连接在返回结果前中断\n");
    process.exitCode = 1;
  } else if (scenario === "permission") {
    output(
      {
        success: false,
        error: {
          category: "permission",
          reason: "forbidden",
          message: "当前账号没有目标目录写入权限",
        },
      },
      1,
    );
  } else if (scenario === "unknown") {
    output(
      {
        success: false,
        status: "unknown",
        error: {
          category: "api",
          reason: "doc_write_commit_unknown",
          message: "文档写入结果未知",
          details: {
            stage: "import",
            state: "unknown",
            status: "unknown",
            taskId: "fake-unknown-task",
          },
        },
      },
      1,
    );
  } else {
    output({
      success: true,
      taskId: "fake-import-task",
      documentUrl: "https://alidocs.dingtalk.com/i/nodes/fake-stage2-node",
      documentType: "1",
    });
  }
} else if (args[0] === "doc" && args[1] === "+fetch") {
  output({
    complete: true,
    status: "success",
    content: {
      success: true,
      nodeId: "fake-stage2-node",
      title: lastImportedName(),
      markdown: [
        "# 阶段 2 自动验收",
        "",
        "正文包含 **加粗** 与 [链接](https://example.com)。",
        "",
        "- 一级列表",
        "  - 二级列表",
        "",
        "| 列 A | 列 B |",
        "| --- | --- |",
        "| A1 | B1 |",
        "",
        "```powershell",
        "Write-Output 'Notion2DingDing'",
        "```",
        "",
        ...Array.from(
          { length: fakeImageCount },
          (_, index) =>
            "![图片" +
            (index + 1) +
            "](https://alidocs.dingtalk.com/resource/fake-image-" +
            (index + 1) +
            ".png)",
        ),
      ].join("\n"),
    },
  });
} else {
  output(
    {
      success: false,
      error: { category: "usage", reason: "unknown_command", message: "未知测试命令" },
    },
    1,
  );
}
