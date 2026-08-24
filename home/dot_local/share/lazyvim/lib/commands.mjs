import { spawnSync } from "node:child_process";

function invokeCommand(command, args, options) {
  const result = spawnSync(command, args, { encoding: "utf8", ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const diagnostic = result.stderr || result.stdout;
    throw new Error(
      `${command} exited with code ${result.status}${diagnostic ? `\n${diagnostic}` : ""}`,
    );
  }
  return result;
}

export function executeCommand(command, args = [], options = {}) {
  invokeCommand(command, args, { stdio: "inherit", ...options });
}

export function captureCommandOutput(command, args = [], options = {}) {
  return invokeCommand(command, args, {
    stdio: "pipe",
    ...options,
  }).stdout.trim();
}
