#!/usr/bin/env node

import { appendFileSync, copyFileSync, existsSync, readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";

const args = process.argv.slice(2);
const scenario = process.env.N2DD_FAKE_SCENARIO ?? "success";
const logPath = process.env.N2DD_FAKE_LOG;
const expectedName = process.env.N2DD_FAKE_EXPECTED_NAME ?? "阶段 2 自动验收";
const requestedImageCount = Number.parseInt(process.env.N2DD_FAKE_IMAGE_COUNT ?? "2", 10);
const fakeImageCount = Number.isSafeInteger(requestedImageCount) && requestedImageCount >= 0
  ? requestedImageCount
  : 2;
const fakeTodoBlockPrefix = process.env.N2DD_FAKE_TODO_BLOCK_PREFIX ?? "fake-todo";
const fakeCodeBlockPrefix = process.env.N2DD_FAKE_CODE_BLOCK_PREFIX ?? "fake-code";
const fakeTableBlockPrefix = process.env.N2DD_FAKE_TABLE_BLOCK_PREFIX ?? "fake-table";
const fakeSubpageBlockPrefix = process.env.N2DD_FAKE_SUBPAGE_BLOCK_PREFIX ?? "fake-subpage";

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
    return expectedName;
  }
  const records = readFileSync(logPath, "utf8")
    .trim()
    .split(/\r?\n/u)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  return [...records].reverse().find((record) => record.args?.includes("+import"))?.name ||
    expectedName;
}

function importRecords() {
  return loggedRecords().filter((record) =>
    record.args?.[0] === "doc" && record.args?.[1] === "+import"
  );
}

function importedNameForNode(node) {
  const match = /fake-tree-node-(?<index>\d+)$/u.exec(String(node ?? ""));
  if (!match) {
    return lastImportedName();
  }
  const index = Number.parseInt(match.groups.index, 10) - 1;
  return importRecords()[index]?.name || expectedName;
}

function fakeTreeLinkMap() {
  const configured = process.env.N2DD_FAKE_TREE_LINKS;
  if (!configured) {
    return null;
  }
  const parsed = JSON.parse(configured);
  return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
}

function fakeTreeImageCount(title) {
  const configured = process.env.N2DD_FAKE_TREE_IMAGE_COUNTS;
  if (!configured) {
    return fakeImageCount;
  }
  const parsed = JSON.parse(configured);
  const value = Number(parsed?.[title]);
  return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

function loggedRecords() {
  if (!logPath || !existsSync(logPath)) {
    return [];
  }
  return readFileSync(logPath, "utf8")
    .trim()
    .split(/\r?\n/u)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function fakeTodoStates() {
  return (process.env.N2DD_FAKE_TODO_STATES ?? "")
    .split(",")
    .map((state) => state.trim())
    .filter(Boolean);
}

function fakeTodoBlocks() {
  const updated = new Set(
    loggedRecords()
      .filter((record) => record.args?.[0] === "doc" && record.args?.[1] === "block" && record.args?.[2] === "update")
      .map((record) => {
        const index = record.args.indexOf("--block-id");
        return index >= 0 ? record.args[index + 1] : "";
      }),
  );
  return fakeTodoStates().map((state, index) => {
    const blockId = `${fakeTodoBlockPrefix}-${index + 1}`;
    const checked = state === "checked";
    const attributes = updated.has(blockId)
      ? {
          uuid: blockId,
          list: {
            listId: `n2dd-${blockId}`,
            level: 0,
            isOrdered: false,
            isTaskList: true,
            isChecked: checked,
          },
        }
      : { uuid: blockId };
    const text = updated.has(blockId)
      ? `阶段 4 待办 ${index + 1}`
      : `${checked ? "☒" : "☐"} 阶段 4 待办 ${index + 1}`;
    return {
      blockId,
      blockType: "p",
      index,
      jsonml: JSON.stringify([
        "p",
        attributes,
        ["span", { "data-type": "text" }, ["span", { "data-type": "leaf" }, text]],
      ]),
    };
  });
}

function fakeCodeDefinitions() {
  const configured = process.env.N2DD_FAKE_CODE_BLOCKS;
  if (!configured) {
    return [{ syntax: "powershell", code: 'Write-Output "Notion2DingDing 阶段 1"' }];
  }
  const parsed = JSON.parse(configured);
  return Array.isArray(parsed) ? parsed : [];
}

function sourceCodeParagraph(blockId, code) {
  const children = [];
  const lines = String(code).replace(/\r\n?/gu, "\n").split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    if (index > 0) {
      children.push(["br", { type: "textWrapping" }]);
    }
    children.push([
      "span",
      { "data-type": "text" },
      ["span", { styleId: "VerbatimChar", "data-type": "leaf" }, lines[index]],
    ]);
  }
  return ["p", { uuid: blockId, styleId: "SourceCode", numPr: {} }, ...children];
}

function fakeCodeBlocks() {
  const updateRecords = loggedRecords().filter((record) =>
    record.args?.[0] === "doc" && record.args?.[1] === "block" && record.args?.[2] === "update"
  );
  return fakeCodeDefinitions().map((definition, index) => {
    const blockId = `${fakeCodeBlockPrefix}-${index + 1}`;
    const updated = [...updateRecords].reverse().find((record) => {
      const blockIndex = record.args.indexOf("--block-id");
      return blockIndex >= 0 && record.args[blockIndex + 1] === blockId;
    });
    let element = sourceCodeParagraph(blockId, definition.code);
    if (updated) {
      const elementIndex = updated.args.indexOf("--element");
      if (elementIndex >= 0) {
        const candidate = JSON.parse(updated.args[elementIndex + 1]);
        if (candidate?.[0] === "code") {
          element = candidate;
        }
      }
    }
    return {
      blockId,
      blockType: element[0],
      index,
      jsonml: JSON.stringify(element),
    };
  });
}

function fakeTableDefinitions() {
  const configured = process.env.N2DD_FAKE_TABLE_SEQUENCE;
  if (!configured) {
    return [];
  }
  const parsed = JSON.parse(configured);
  return Array.isArray(parsed) ? parsed : [];
}

function fakeTableElement(blockId, definition, tableIndex) {
  const columnCount = Number(definition.columnCount);
  const widths = Array.from({ length: columnCount }, () => 200);
  const cells = Array.from({ length: columnCount }, (_, index) => [
    "tc",
    { uuid: `${blockId}-cell-${index + 1}`, colSpan: 1, rowSpan: 1, bdr: { all: "single" } },
    [
      "p",
      { uuid: `${blockId}-p-${index + 1}` },
      ["span", { "data-type": "text" }, ["span", { "data-type": "leaf" }, `单元格 ${index + 1}`]],
    ],
  ]);
  const element = [
    "table",
    {
      uuid: blockId,
      colsWidth: widths,
      bdr: { all: "single" },
      styleId: definition.kind === "layout" ? "Notion Columns" : "Table",
    },
    ["tr", { uuid: `${blockId}-row` }, ...cells],
  ];
  const invalidListStartIndex = Number.parseInt(
    process.env.N2DD_FAKE_INVALID_LAYOUT_LIST_START_INDEX ?? "",
    10,
  );
  if (Number.isSafeInteger(invalidListStartIndex) && invalidListStartIndex === tableIndex) {
    element[2][2][2][1].list = { start: 0 };
  }
  return element;
}

function fakeTableBlocks() {
  const updateRecords = loggedRecords().filter((record) =>
    record.args?.[0] === "doc" && record.args?.[1] === "block" && record.args?.[2] === "update"
  );
  const omittedTableIndex = Number.parseInt(process.env.N2DD_FAKE_OMIT_TABLE_INDEX ?? "", 10);
  return fakeTableDefinitions().flatMap((definition, index) => {
    if (Number.isSafeInteger(omittedTableIndex) && omittedTableIndex === index + 1) {
      return [];
    }
    const blockId = `${fakeTableBlockPrefix}-${index + 1}`;
    let element = fakeTableElement(blockId, definition, index + 1);
    const updated = [...updateRecords].reverse().find((record) => {
      const blockIndex = record.args.indexOf("--block-id");
      return blockIndex >= 0 && record.args[blockIndex + 1] === blockId;
    });
    if (updated) {
      const elementIndex = updated.args.indexOf("--element");
      if (elementIndex >= 0) {
        const candidate = JSON.parse(updated.args[elementIndex + 1]);
        if (candidate?.[0] === "table") {
          element = candidate;
        }
      }
    }
    return [{
      blockId,
      blockType: "table",
      index,
      jsonml: JSON.stringify(element),
    }];
  });
}

function fakeSubpageDefinitions() {
  const configured = process.env.N2DD_FAKE_SUBPAGE_LINKS;
  if (!configured) {
    return [];
  }
  const parsed = JSON.parse(configured);
  return Array.isArray(parsed) ? parsed : [];
}

function fakeSubpageLinkElement(blockId, definition, index) {
  return [
    "table",
    {
      uuid: blockId,
      colsWidth: [528],
      styleId: "FigureTable",
    },
    [
      "tr",
      { uuid: `${blockId}-row` },
      [
        "tc",
        { uuid: `${blockId}-cell`, colSpan: 1, rowSpan: 1 },
        [
          "p",
          { uuid: `${blockId}-paragraph`, styleId: "Compact", jc: "center" },
          [
            "a",
            { uuid: `${blockId}-link-${index + 1}`, href: "" },
            [
              "span",
              { "data-type": "text" },
              ["span", { "data-type": "leaf", styleId: "Hyperlink" }, definition.label],
            ],
          ],
        ],
      ],
    ],
  ];
}

function fakeSubpageBlocks() {
  const definitions = fakeSubpageDefinitions();
  const updateRecords = loggedRecords().filter((record) =>
    record.args?.[0] === "doc" && record.args?.[1] === "block" && record.args?.[2] === "update"
  );
  const deletedBlockIds = new Set(
    loggedRecords()
      .filter((record) =>
        record.args?.[0] === "doc" && record.args?.[1] === "block" &&
        record.args?.[2] === "delete"
      )
      .map((record) => {
        const blockIndex = record.args.indexOf("--block-id");
        return blockIndex >= 0 ? record.args[blockIndex + 1] : "";
      }),
  );
  const linkBlocks = definitions.flatMap((definition, index) => {
    const blockId = `${fakeSubpageBlockPrefix}-link-${index + 1}`;
    if (deletedBlockIds.has(blockId)) {
      return [];
    }
    let element = fakeSubpageLinkElement(blockId, definition, index);
    const updated = [...updateRecords].reverse().find((record) => {
      const blockIndex = record.args.indexOf("--block-id");
      return blockIndex >= 0 && record.args[blockIndex + 1] === blockId;
    });
    if (updated) {
      const elementIndex = updated.args.indexOf("--element");
      if (elementIndex >= 0) {
        const candidate = JSON.parse(updated.args[elementIndex + 1]);
        if (["table", "toc"].includes(candidate?.[0])) {
          element = candidate;
        }
      }
    }
    return [{
      blockId,
      blockType: element[0],
      jsonml: JSON.stringify(element),
    }];
  });
  const targets = new Map();
  for (const definition of definitions) {
    if (!targets.has(definition.targetPageIndex)) {
      targets.set(definition.targetPageIndex, definition.targetTitle);
    }
  }
  const headingBlocks = [...targets.entries()]
    .sort(([left], [right]) => Number(left) - Number(right))
    .map(([pageIndex, title]) => {
      const blockId = `${fakeSubpageBlockPrefix}-heading-${pageIndex}`;
      return {
        blockId,
        blockType: "h2",
        jsonml: JSON.stringify([
          "h2",
          { uuid: blockId, styleId: "Heading2" },
          ["span", { "data-type": "text" }, ["span", { "data-type": "leaf" }, title]],
        ]),
      };
    });
  const idlessImageWrapper = {
    blockId: "",
    blockType: "p",
    jsonml: JSON.stringify([
      "p",
      {},
      ["span", { "data-type": "text" }, ["span", { "data-type": "leaf" }, ""]],
      ["img", { uuid: `${fakeSubpageBlockPrefix}-decorative-image`, src: "/fake/image.png" }],
    ]),
  };
  return [idlessImageWrapper, ...linkBlocks, ...headingBlocks];
}

function fakeTreeSubpageBlocks(node) {
  const linkMap = fakeTreeLinkMap();
  if (!linkMap) {
    return [];
  }
  const title = importedNameForNode(node);
  const definitions = Array.isArray(linkMap[title]) ? linkMap[title] : [];
  const updateRecords = loggedRecords().filter((record) =>
    record.args?.[0] === "doc" && record.args?.[1] === "block" &&
    record.args?.[2] === "update" && optionFrom(record.args, "--node") === node
  );
  return definitions.map((definition, index) => {
    const blockId = `fake-tree-link-${index + 1}`;
    const updated = [...updateRecords].reverse().find((record) =>
      optionFrom(record.args, "--block-id") === blockId
    );
    let element = fakeSubpageLinkElement(blockId, definition, index);
    if (updated) {
      const serialized = optionFrom(updated.args, "--element");
      if (serialized) {
        element = JSON.parse(serialized);
      }
    }
    return { blockId, blockType: element[0], jsonml: JSON.stringify(element) };
  });
}

function optionFrom(values, name) {
  const index = values.indexOf(name);
  return index >= 0 ? values[index + 1] : undefined;
}

function output(value, status = 0) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
  process.exitCode = status;
}

logCall();

if (args[0] === "--version") {
  process.stdout.write("dws version v1.0.59 (stage4-fake)\n");
} else if (args[0] === "auth" && args[1] === "status") {
  if (scenario === "unauthenticated") {
    output({ success: true, authenticated: false, token_valid: false });
  } else {
    output({ success: true, authenticated: true, token_valid: true });
  }
} else if (args[0] === "wiki" && args[1] === "space" && args[2] === "list") {
  const type = option("--type");
  output({
    arguments: [],
    errorCode: null,
    errorMsg: null,
    result: {
      items: type === "mySpace"
        ? [{
            rootFolderId: "fake-my-root",
            spaceId: "10001",
            spaceName: "我的文件",
            spaceType: "mySpace",
          }]
        : [{
            rootFolderId: "fake-org-root",
            spaceId: "20001",
            spaceName: "测试企业空间",
            spaceType: "orgSpace",
          }],
    },
    success: true,
  });
} else if (args[0] === "drive" && args[1] === "+list") {
  const folder = option("--folder");
  const cursor = option("--cursor");
  if (folder === "fake-my-root" && !cursor) {
    output({
      ok: true,
      outcome: "success",
      data: {
        count: 2,
        files: [
          { name: "项目资料", nodeId: "fake-folder-project", type: "FOLDER" },
          { name: "普通文件.txt", nodeId: "fake-file", type: "FILE" },
        ],
        nextCursor: "fake-page-2",
      },
    });
  } else if (folder === "fake-my-root" && cursor === "fake-page-2") {
    output({
      ok: true,
      outcome: "success",
      data: {
        count: 1,
        files: [{ name: "归档", nodeId: "fake-folder-archive", type: "FOLDER" }],
      },
    });
  } else if (folder === "fake-folder-project") {
    output({
      ok: true,
      outcome: "success",
      data: {
        count: 1,
        files: [{ name: "子目录", nodeId: "fake-folder-child", type: "FOLDER" }],
      },
    });
  } else {
    output({ ok: true, outcome: "success", data: { count: 0, files: [] } });
  }
} else if (args[0] === "drive" && args[1] === "+search") {
  const cursor = option("--cursor");
  if (!cursor) {
    output({
      ok: true,
      outcome: "success",
      data: {
        count: 2,
        files: [
          { name: "Notion2DingDing 验证输出", nodeId: "fake-orphan-folder", type: "FOLDER" },
          { name: "Notion2DingDing 验证输出说明.txt", nodeId: "fake-search-file", type: "FILE" },
        ],
        nextCursor: "fake-search-page-2",
      },
    });
  } else {
    output({
      ok: true,
      outcome: "success",
      data: {
        count: 1,
        files: [{ name: "Notion2DingDing 验证输出归档", nodeId: "fake-search-archive", type: "FOLDER" }],
      },
    });
  }
} else if (args[0] === "wiki" && args[1] === "+node-get") {
  const workspaceId = process.env.N2DD_FAKE_FOLDER_WORKSPACE_ID;
  if (workspaceId) {
    output({
      ok: true,
      outcome: "success",
      data: {
        success: true,
        workspaceId,
        nodeId: option("--node"),
        nodeType: "folder",
        name: "测试保存位置",
      },
    });
  } else {
    output({ ok: false, outcome: "failure", error: { message: "不是 Workspace 节点" } }, 1);
  }
} else if (args[0] === "drive" && args[1] === "+inspect") {
  output({
    ok: true,
    outcome: "success",
    data: {
      complete: true,
      data: { file: { fileId: option("--node"), type: "FOLDER" } },
      status: "success",
    },
  });
} else if (args[0] === "drive" && args[1] === "mkdir") {
  const count = loggedRecords().filter((record) =>
    record.args?.[0] === "drive" && record.args?.[1] === "mkdir"
  ).length;
  output({
    ok: true,
    outcome: "success",
    data: { fileId: `fake-tree-folder-${count}`, nodeId: `fake-tree-folder-${count}` },
  });
} else if (args[0] === "wiki" && args[1] === "+node-list") {
  const existingName = process.env.N2DD_FAKE_EXISTING_TREE_FOLDER;
  output({
    ok: true,
    outcome: "success",
    data: {
      autoPageComplete: true,
      count: existingName ? 1 : 0,
      hasMore: false,
      nodes: existingName
        ? [{ name: existingName, nodeId: "fake-existing-tree-folder", type: "folder" }]
        : [],
      pagesFetched: 1,
    },
  });
} else if (args[0] === "wiki" && args[1] === "+node-create") {
  const count = loggedRecords().filter((record) =>
    record.args?.[0] === "wiki" && record.args?.[1] === "+node-create"
  ).length;
  if (process.env.N2DD_FAKE_WIKI_FOLDER_UNKNOWN === "1") {
    output({ ok: false, outcome: "unknown", error: { message: "创建响应缺少节点 ID" } }, 1);
  } else {
    output({
      ok: true,
      outcome: "success",
      data: { nodeId: `fake-tree-wiki-folder-${count}` },
    });
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
  } else if (scenario === "framed-permission") {
    process.stdout.write(`${JSON.stringify({ stage: "upload", progress: 100 })}\n`);
    process.stdout.write("\u001b[31m");
    process.stdout.write(`${JSON.stringify({
      success: false,
      error: {
        type: "api",
        subtype: "permission_denied",
        message: "当前账号没有目标目录写入权限",
      },
    }, null, 2)}\n`);
    process.stdout.write("\u001b[0m");
    process.exitCode = 1;
  } else if (scenario === "stderr-permission") {
    process.stderr.write(`${JSON.stringify({
      success: false,
      error: {
        type: "api",
        subtype: "permission_denied",
        message: "当前账号没有目标目录写入权限",
      },
    }, null, 2)}\n`);
    process.exitCode = 1;
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
    const treeLinks = fakeTreeLinkMap();
    const importCount = importRecords().length;
    const nodeId = treeLinks ? `fake-tree-node-${importCount}` : "fake-stage2-node";
    output({
      success: true,
      taskId: treeLinks ? `fake-tree-import-task-${importCount}` : "fake-import-task",
      documentUrl: `https://alidocs.dingtalk.com/i/nodes/${nodeId}`,
      documentType: "1",
    });
  }
} else if (args[0] === "doc" && args[1] === "+resource-update") {
  const coverFile = option("--file");
  if (!args.includes("--yes")) {
    output({
      ok: false,
      status: "failure",
      error: { reason: "confirmation_required", message: "该操作需要显式确认" },
    }, 1);
  } else if (!coverFile || !existsSync(path.resolve(coverFile))) {
    output({ ok: false, status: "failure", error: { message: "封面文件不存在" } }, 1);
  } else if (scenario === "cover-update-unknown") {
    output({ ok: false, status: "unknown", error: { message: "封面写入状态未知" } }, 1);
  } else {
    output({ ok: true, status: "success", complete: true, data: { success: true, resourceId: "fake-cover-resource" } });
  }
} else if (args[0] === "doc" && args[1] === "+inspect") {
  const node = option("--node");
  const coverPresent = loggedRecords().some((record) =>
    record.args?.[0] === "doc" && record.args?.[1] === "+resource-update" &&
    record.args.includes("--yes") && optionFrom(record.args, "--node") === node
  );
  output({
    ok: true,
    status: "success",
    complete: true,
    data: {
      document: { success: true, nodeId: String(node ?? "").split("/").at(-1) },
      style: {
        success: true,
        nodeId: String(node ?? "").split("/").at(-1),
        ...(coverPresent ? { resourceId: "fake-cover-resource" } : {}),
      },
    },
  });
} else if (args[0] === "doc" && args[1] === "block" && args[2] === "list") {
  const node = option("--node");
  const tableBlocks = fakeTableBlocks();
  const subpageBlocks = fakeSubpageBlocks();
  const treeSubpageBlocks = fakeTreeSubpageBlocks(node);
  const codeBlocks = fakeCodeBlocks();
  const todoBlocks = fakeTodoBlocks();
  const blocks = [...tableBlocks, ...subpageBlocks, ...treeSubpageBlocks, ...codeBlocks, ...todoBlocks]
    .map((block, index) => ({ ...block, index }));
  output({ success: true, blocks, totalCount: blocks.length, hasMore: false });
} else if (args[0] === "doc" && args[1] === "block" && args[2] === "update") {
  const scenarioUpdateCount = loggedRecords().filter((record) =>
    record.scenario === scenario &&
    record.args?.[0] === "doc" &&
    record.args?.[1] === "block" &&
    record.args?.[2] === "update"
  ).length;
  if (scenario === "todo-update-unknown-once" && scenarioUpdateCount === 1) {
    output({
      success: false,
      status: "unknown",
      error: { reason: "todo_write_commit_unknown", message: "待办块更新结果未知" },
    }, 1);
  } else if (scenario === "todo-update-no-ack") {
    output({ blockId: option("--block-id"), message: "Block updated successfully via JSONML." });
  } else if (scenario === "code-update-unknown-once" && scenarioUpdateCount === 1) {
    output({
      success: false,
      status: "unknown",
      error: { reason: "code_write_commit_unknown", message: "代码块更新结果未知" },
    }, 1);
  } else if (scenario === "layout-update-unknown-once" && scenarioUpdateCount === 1) {
    output({
      success: false,
      status: "unknown",
      error: { reason: "layout_write_commit_unknown", message: "分栏更新结果未知" },
    }, 1);
  } else if (
    scenario === "subpage-update-unknown-once" &&
    option("--block-id")?.startsWith(`${fakeSubpageBlockPrefix}-link-`) &&
    loggedRecords().filter((record) => {
      const blockIndex = record.args?.indexOf("--block-id") ?? -1;
      return record.args?.[0] === "doc" && record.args?.[1] === "block" &&
        record.args?.[2] === "update" && blockIndex >= 0 &&
        String(record.args[blockIndex + 1]).startsWith(`${fakeSubpageBlockPrefix}-link-`);
    }).length === 1
  ) {
    output({
      success: false,
      status: "unknown",
      error: { reason: "subpage_write_commit_unknown", message: "子页面目录更新结果未知" },
    }, 1);
  } else {
    output({ success: true, blockId: option("--block-id") });
  }
} else if (args[0] === "doc" && args[1] === "block" && args[2] === "delete") {
  const subpageDeleteCount = loggedRecords().filter((record) =>
    record.args?.[0] === "doc" && record.args?.[1] === "block" &&
    record.args?.[2] === "delete" &&
    String(record.args?.[record.args.indexOf("--block-id") + 1] ?? "")
      .startsWith(`${fakeSubpageBlockPrefix}-link-`)
  ).length;
  if (scenario === "subpage-delete-unknown-once" && subpageDeleteCount === 1) {
    output({
      success: false,
      status: "unknown",
      error: { reason: "subpage_delete_commit_unknown", message: "旧子页面入口删除结果未知" },
    }, 1);
  } else {
    output({ success: true, blockId: option("--block-id") });
  }
} else if (args[0] === "doc" && args[1] === "+fetch") {
  const node = option("--node");
  const importedName = importedNameForNode(node);
  const readbackTitle = scenario === "decorated-readback"
    ? `${importedName}(1)`
    : scenario === "readback-mismatch"
      ? `不匹配-${importedName}`
      : importedName;
  const inlineSvgCount = scenario === "decorated-readback" ? 3 : 0;
  const readbackImageTotal = fakeTreeLinkMap() ? fakeTreeImageCount(importedName) : fakeImageCount;
  output({
    complete: true,
    status: "success",
    content: {
      success: true,
      nodeId: String(node ?? "").split("/").at(-1) || "fake-stage2-node",
      title: readbackTitle,
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
          { length: readbackImageTotal },
          (_, index) =>
            "![图片" +
            (index + 1) +
            "](https://alidocs.dingtalk.com/resource/fake-image-" +
            (index + 1) +
            ".png)",
        ),
        ...Array.from(
          { length: inlineSvgCount },
          () => "![image.svg](data:image/svg+xml;base64,PHN2Zy8+)",
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
