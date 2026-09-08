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
	item.path?.replaceAll("\\", "/").includes("/pi-web-access/"),
);
if (packageErrors.length > 0) {
	throw new Error(`Pi extension diagnostic: ${packageErrors.map((item) => item.error).join("; ")}`);
}
const extension = extensions.extensions.find((item) =>
	item.resolvedPath.replaceAll("\\", "/").endsWith("/pi-web-access/index.ts"),
);
if (!extension) {
	throw new Error("Pi did not discover the pi-web-access extension");
}
for (const tool of ["web_search", "source_check", "fetch_content", "get_search_content"]) {
	if (!extension.tools.has(tool)) {
		throw new Error(`pi-web-access did not register ${tool}`);
	}
}

console.log("pi-web-access");
