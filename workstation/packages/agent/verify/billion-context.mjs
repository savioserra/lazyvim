import path from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import os from "node:os";
import fs from "node:fs";

const [packageRoot] = process.argv.slice(2);
if (!packageRoot) {
	throw new Error("usage: node verify.mjs <pi-package-root>");
}

const pi = await import(pathToFileURL(path.join(packageRoot, "dist", "index.js")).href);
const loader = new pi.DefaultResourceLoader({ cwd: process.cwd(), agentDir: pi.getAgentDir() });
await loader.reload();

const extensions = loader.getExtensions();
const packageErrors = extensions.errors.filter((item) =>
	item.path?.replaceAll("\\", "/").includes("/billion-context/"),
);
if (packageErrors.length > 0) {
	throw new Error(`Pi extension diagnostic: ${packageErrors.map((item) => item.error).join(";")}`);
}
const extension = extensions.extensions.find((item) =>
	item.resolvedPath.replaceAll("\\", "/").endsWith("/billion-context/dist/agent/pi-native.js"),
);
if (!extension) {
	throw new Error("Pi did not discover the billion-context extension");
}
// The pi-native surface registers commands only; the compression tools
// (compress/decompress/search_context/acp_status/acp_cache) are exposed
// through the bili ACP proxy surface, proven separately by the proxy health
// receipt below.
for (const command of ["acp", "acp-cache", "acp-rule"]) {
	if (!extension.commands?.has(command)) {
		throw new Error(`billion-context did not register ${command}`);
	}
}
if (extension.tools.has("acp_delegate")) {
	throw new Error("billion-context acp_delegate must stay disabled; the pi-fabric runtime owns delegation");
}

// Canonical install + proxy health receipts: the registry pin is the source of
// truth; the host binary must be installed through the canonical global npm
// flow and answer with the pinned version, and the proxy must pass its
// end-to-end pi-path check.
const registryPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "pi-packages.json");
const registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
const pin = registry.pi_packages.find((entry) => entry.name === "billion-context");
if (!pin) {
	throw new Error("pi-packages.json has no billion-context entry");
}
const localPrefix = path.join(os.homedir(), ".local");
execFileSync("npm", ["install", "-g", "billion-context", `--prefix=${localPrefix}`], {
	stdio: ["ignore", "pipe", "pipe"],
});
const biliBin = path.join(localPrefix, "bin", "bili");
const version = execFileSync(biliBin, ["--version"], { encoding: "utf8" }).trim();
if (!version.startsWith(pin.version)) {
	throw new Error(`bili version ${version} does not match the pinned ${pin.version}`);
}
const health = execFileSync(biliBin, ["test", "pi"], { encoding: "utf8", timeout: 180000 });
if (!/^OK\s*$/m.test(health)) {
	throw new Error(`bili proxy health check failed: ${health.trim()}`);
}
console.log(`billion-context discovery OK (acp/acp-cache/acp-rule); bili ${version} canonical install + proxy health OK`);
