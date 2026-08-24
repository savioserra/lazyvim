process.argv.splice(2, 0, "sync");
await import("./run.mjs");
