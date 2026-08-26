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
	item.path?.replaceAll("\\", "/").includes("/pi-subagents/"),
);
if (packageErrors.length > 0) {
	throw new Error(`Pi extension diagnostic: ${packageErrors.map((item) => item.error).join("; ")}`);
}
const extension = extensions.extensions.find((item) =>
	item.resolvedPath.replaceAll("\\", "/").endsWith("/pi-subagents/index.ts"),
);
if (!extension) {
	throw new Error("Pi did not discover the pi-subagents extension");
}
for (const tool of ["subagent", "subagent_wait"]) {
	if (!extension.tools.has(tool)) {
		throw new Error(`pi-subagents did not register ${tool}`);
	}
}

const { skills, diagnostics } = loader.getSkills();
for (const diagnostic of diagnostics) {
	if (diagnostic.path?.replaceAll("\\", "/").includes("/pi-subagents/")) {
		throw new Error(`Pi package skill diagnostic: ${diagnostic.message ?? JSON.stringify(diagnostic)}`);
	}
}
if (!skills.some((skill) => skill.name === "pi-subagents")) {
	throw new Error("Pi did not discover the bundled pi-subagents skill");
}

console.log("pi-subagents");
