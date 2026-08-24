process.argv.splice(2, 0, "setup");
await import("./run.mjs");
