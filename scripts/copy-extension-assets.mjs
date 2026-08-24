import { cp, copyFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");
const extensionRoot = path.join(repositoryRoot, "apps", "edge-extension");
const outputDirectory = path.join(repositoryRoot, "dist", "edge-extension");

await mkdir(outputDirectory, { recursive: true });
await copyFile(
  path.join(extensionRoot, "manifest.json"),
  path.join(outputDirectory, "manifest.json"),
);
await cp(path.join(extensionRoot, "public"), outputDirectory, {
  recursive: true,
  force: true,
});

process.stdout.write(`Edge extension built at ${outputDirectory}\n`);
