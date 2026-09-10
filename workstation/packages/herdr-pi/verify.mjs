import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [packageRoot, deployedHook] = process.argv.slice(2);
if (!packageRoot || !deployedHook) {
	throw new Error("usage: node verify.mjs <pi-package-root> <deployed-hook>");
}
// Stay inert even when the lifecycle itself runs inside a Herdr pane: the
// official hook activates only under a full Herdr environment.
delete process.env.HERDR_ENV;

const scratch = await fs.mkdtemp(path.join(os.tmpdir(), "herdr-pi-verify-"));
try {
	// Isolated agent directory containing only the deployed hook: Pi's loader
	// discovers it without executing any ambient user extension.
	const extensionsDir = path.join(scratch, "extensions");
	await fs.mkdir(extensionsDir);
	await fs.copyFile(deployedHook, path.join(extensionsDir, "herdr-agent-state.ts"));

	const pi = await import(pathToFileURL(path.join(packageRoot, "dist", "index.js")).href);
	const loader = new pi.DefaultResourceLoader({ cwd: scratch, agentDir: scratch });
	await loader.reload();

	const result = loader.getExtensions();
	const errors = result.errors.filter((item) =>
		String(item.path).replaceAll("\\", "/").includes("herdr-agent-state.ts")
	);
	if (errors.length > 0) {
		throw new Error(`Herdr hook diagnostic: ${errors.map((item) => item.error).join("; ")}`);
	}
	const discovered = result.extensions.find((item) =>
		String(item.resolvedPath).replaceAll("\\", "/").endsWith("herdr-agent-state.ts")
	);
	if (!discovered) {
		throw new Error("Pi did not discover the official Herdr hook");
	}
	console.log("herdr-pi");
} finally {
	await fs.rm(scratch, { recursive: true, force: true });
}
