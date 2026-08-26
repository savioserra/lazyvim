import path from "node:path";
import { pathToFileURL } from "node:url";

const [packageRoot, expectedName] = process.argv.slice(2);
if (!packageRoot || !expectedName) {
	throw new Error("usage: node verify.mjs <pi-package-root> <skill-name>");
}

const pi = await import(pathToFileURL(path.join(packageRoot, "dist", "index.js")).href);
const loader = new pi.DefaultResourceLoader({ cwd: process.cwd(), agentDir: pi.getAgentDir() });
await loader.reload();
const { skills, diagnostics } = loader.getSkills();
for (const diagnostic of diagnostics) {
	if (diagnostic.message?.includes(expectedName) || diagnostic.path?.includes(expectedName)) {
		throw new Error(`Pi skill diagnostic: ${diagnostic.message ?? JSON.stringify(diagnostic)}`);
	}
}
if (!skills.some((skill) => skill.name === expectedName)) {
	throw new Error(`Pi did not discover managed skill: ${expectedName}`);
}
console.log(expectedName);
