import path from "node:path";
import { pathToFileURL } from "node:url";

const [packageRoot, bridgeRoot, actorClientRoot] = process.argv.slice(2);
if (!packageRoot || !bridgeRoot || !actorClientRoot) throw new Error("usage: node verify.mjs <pi-package-root> <bridge-root> <actor-client-root>");

const pi = await import(pathToFileURL(path.join(packageRoot, "dist", "index.js")).href);
const loader = new pi.DefaultResourceLoader({ cwd: process.cwd(), agentDir: pi.getAgentDir() });
await loader.reload();
const extensions = loader.getExtensions();

function requireExtension(root, expectedCommands) {
  const normalized = root.replaceAll("\\", "/");
  const diagnostics = extensions.errors.filter((item) => item.path?.replaceAll("\\", "/").startsWith(normalized));
  if (diagnostics.length > 0) throw new Error(`actor extension diagnostic: ${diagnostics.map((item) => item.error).join("; ")}`);
  const extension = extensions.extensions.find((item) => item.resolvedPath.replaceAll("\\", "/") === `${normalized}/index.ts`);
  if (!extension) throw new Error(`Pi did not discover ${normalized}/index.ts`);
  for (const command of expectedCommands) {
    if (!extension.commands.has(command)) throw new Error(`extension did not register ${command}`);
  }
  return extension;
}

const bridge = requireExtension(bridgeRoot, []);
for (const command of ["actor-list", "actor-resolve", "actor-send", "actor-ask", "actor-abort", "actor-shutdown", "actor-subscribe", "actor-unsubscribe"]) {
  if (bridge.commands.has(command)) throw new Error(`hosted bridge registered ${command} outside a hosted runtime`);
}
requireExtension(actorClientRoot, ["actor-list", "actor-resolve", "actor-send", "actor-ask", "actor-create", "actor-abort", "actor-shutdown", "actor-subscribe", "actor-unsubscribe"]);
console.log("subagents actor client active");
