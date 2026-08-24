process.argv.splice(2, 0, "verify");
await import("./run.mjs");
