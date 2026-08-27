import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [packageRoot, expectedSubagentsVersion] = process.argv.slice(2);
if (!packageRoot || !expectedSubagentsVersion) {
	throw new Error("usage: node verify.mjs <pi-package-root> <pi-subagents-version>");
}

const agentDir = path.join(process.env.HOME, ".pi", "agent");
const subagentsManifest = JSON.parse(
	fs.readFileSync(path.join(agentDir, "npm", "node_modules", "pi-subagents", "package.json"), "utf8"),
);
if (subagentsManifest.version !== expectedSubagentsVersion) {
	throw new Error(`tmux-subagents expected pi-subagents ${expectedSubagentsVersion}, got ${subagentsManifest.version}`);
}

const pi = await import(pathToFileURL(path.join(packageRoot, "dist", "index.js")).href);
const loader = new pi.DefaultResourceLoader({ cwd: process.cwd(), agentDir });
await loader.reload();
const extensions = loader.getExtensions();
const matchingErrors = extensions.errors.filter((item) =>
	item.path?.replaceAll("\\", "/").includes("/tmux-subagents/"),
);
if (matchingErrors.length > 0) {
	throw new Error(`tmux-subagents extension diagnostic: ${matchingErrors.map((item) => item.error).join("; ")}`);
}
const extension = extensions.extensions.find((item) =>
	item.resolvedPath.replaceAll("\\", "/").endsWith("/tmux-subagents/index.ts"),
);
if (!extension) throw new Error("Pi did not discover the managed tmux-subagents extension");
if (!extension.commands.has("tmux-subagents")) {
	throw new Error("tmux-subagents extension did not register its command");
}

const { skills, diagnostics } = loader.getSkills();
for (const diagnostic of diagnostics) {
	if (diagnostic.path?.replaceAll("\\", "/").includes("/tmux-subagents/")) {
		throw new Error(`tmux-subagents skill diagnostic: ${diagnostic.message ?? JSON.stringify(diagnostic)}`);
	}
}
if (!skills.some((skill) => skill.name === "tmux-subagents")) {
	throw new Error("Pi did not discover the managed tmux-subagents skill");
}
console.log("tmux-subagents");
