import path from "node:path";
import { pathToFileURL } from "node:url";

const [packageRoot, bridgeRoot] = process.argv.slice(2);
if (!packageRoot || !bridgeRoot) throw new Error("usage: node verify.mjs <pi-package-root> <bridge-root>");

const pi = await import(pathToFileURL(path.join(packageRoot, "dist", "index.js")).href);
const loader = new pi.DefaultResourceLoader({ cwd: process.cwd(), agentDir: pi.getAgentDir() });
await loader.reload();
const extensions = loader.getExtensions();
const normalized = bridgeRoot.replaceAll("\\", "/");
const diagnostics = extensions.errors.filter((item) => item.path?.replaceAll("\\", "/").startsWith(normalized));
if (diagnostics.length > 0) throw new Error(`hosted Pi bridge diagnostic: ${diagnostics.map((item) => item.error).join("; ")}`);
const extension = extensions.extensions.find((item) => item.resolvedPath.replaceAll("\\", "/") === `${normalized}/index.ts`);
if (!extension) throw new Error("Pi did not discover the repository-managed hosted Pi bridge");
for (const command of ["actor-list", "actor-resolve", "actor-send", "actor-ask", "actor-abort", "actor-shutdown", "actor-subscribe", "actor-unsubscribe"]) {
  if (extension.commands.has(command)) throw new Error(`inactive hosted Pi bridge registered ${command}`);
}
console.log("hosted-pi-bridge inactive");
