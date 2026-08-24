import { createCapabilityContext } from "./capabilities/context.mjs";
import { createCapabilityRegistry } from "./capabilities/registry.mjs";

const lifecycle = process.argv[2];
if (!new Set(["setup", "sync", "verify"]).has(lifecycle)) {
  throw new Error("Usage: node run.mjs <setup|sync|verify>");
}

const context = createCapabilityContext();
const registry = createCapabilityRegistry(context);
await registry.run(lifecycle);
console.log(`\n${lifecycle} complete (${context.platform.platformName}).`);
