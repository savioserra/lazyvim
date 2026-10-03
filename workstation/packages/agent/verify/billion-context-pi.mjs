import path from "node:path";
import { pathToFileURL } from "node:url";

const [packageRoot] = process.argv.slice(2);
if (!packageRoot) {
	throw new Error("usage: node verify.mjs <pi-package-root>");
}

const pi = await import(pathToFileURL(path.join(packageRoot, "dist", "index.js")).href);
const loader = new pi.DefaultResourceLoader({ cwd: process.cwd(), agentDir: pi.getAgentDir() });
await loader.reload();

const extensions = loader.getExtensions();
const packageErrors = extensions.errors.filter((item) =>
	item.path?.replaceAll("\\", "/").includes("/billion-context-pi/"),
);
if (packageErrors.length > 0) {
	throw new Error(`Pi extension diagnostic: ${packageErrors.map((item) => item.error).join("; ")}`);
}
const extension = extensions.extensions.find((item) =>
	item.resolvedPath.replaceAll("\\", "/").endsWith("/billion-context-pi/dist/index.js"),
);
if (!extension) {
	throw new Error("Pi did not discover the billion-context-pi extension");
}
for (const tool of ["compress", "decompress", "search_context", "acp_status"]) {
	if (!extension.tools.has(tool)) {
		throw new Error(`billion-context-pi did not register ${tool}`);
	}
}
if (extension.tools.has("acp_delegate")) {
	throw new Error("billion-context-pi acp_delegate must stay disabled; pi-subagents owns delegation");
}
