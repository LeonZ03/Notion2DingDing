import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { basename, join } from "node:path";

const hostPath = join(
  process.env.LOCALAPPDATA ?? "",
  "Programs",
  "Notion2DingDingNativeHost",
  "notion2dingding-host.exe",
);
const inspectIndex = process.argv.indexOf("--inspect");
const inspectPath = inspectIndex >= 0 ? process.argv[inspectIndex + 1] : undefined;
if (inspectIndex >= 0 && !inspectPath) {
  throw new Error("--inspect 需要提供 Notion HTML ZIP 路径。");
}
const inspectContent = inspectPath ? await readFile(inspectPath) : undefined;
const request = {
  protocolVersion: 1,
  requestId: `doctor-${Date.now()}`,
  method: inspectContent ? "migration.inspect" : "health.check",
  params: inspectContent
    ? { fileName: basename(inspectPath), contentBase64: inspectContent.toString("base64") }
    : {},
};
const payload = Buffer.from(JSON.stringify(request), "utf8");
const header = Buffer.alloc(4);
header.writeUInt32LE(payload.length);

const child = spawn(hostPath, [], {
  stdio: ["pipe", "pipe", "pipe"],
  windowsHide: true,
});
const stdout = [];
const stderr = [];
child.stdout.on("data", (chunk) => stdout.push(chunk));
child.stderr.on("data", (chunk) => stderr.push(chunk));
child.stdin.end(Buffer.concat([header, payload]));

const exitCode = await new Promise((accept, reject) => {
  child.once("error", reject);
  child.once("exit", accept);
});
if (exitCode !== 0) {
  throw new Error(`Native Host 退出码 ${exitCode}：${Buffer.concat(stderr).toString("utf8")}`);
}
const output = Buffer.concat(stdout);
if (output.length < 4) {
  throw new Error("Native Host 没有返回长度前缀响应。");
}
const responseLength = output.readUInt32LE(0);
if (output.length !== responseLength + 4) {
  throw new Error("Native Host stdout 包含非协议内容或响应不完整。");
}
const response = JSON.parse(output.subarray(4).toString("utf8"));
if (!response.ok) {
  throw new Error(response.error?.message ?? "Native Host 健康检查失败。");
}
console.log(JSON.stringify(response, null, 2));
