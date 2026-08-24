import { spawnSync } from "node:child_process";

export function run(command, args = [], options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: options.capture ? "pipe" : "inherit",
    ...options,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const detail = options.capture ? `\n${result.stderr || result.stdout}` : "";
    throw new Error(`${command} exited with code ${result.status}${detail}`);
  }
  return options.capture ? result.stdout.trim() : "";
}

export function output(command, args = [], options = {}) {
  return run(command, args, { ...options, capture: true });
}
