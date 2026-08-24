import fs from "node:fs";
import path from "node:path";
import { captureCommandOutput, executeCommand } from "./commands.mjs";
import { localDirectory, targetHome } from "./paths.mjs";
import { versions } from "./versions.mjs";

export function configureNvmDefaultOnUnix() {
  const aliasDirectory = path.join(localDirectory, "opt", "nvm", "alias");
  fs.mkdirSync(aliasDirectory, { recursive: true });
  fs.writeFileSync(path.join(aliasDirectory, "default"), `${versions.node}\n`);
}

function readWindowsUserEnvironmentVariable(name) {
  try {
    const registryOutput = captureCommandOutput("reg.exe", [
      "query",
      "HKCU\\Environment",
      "/v",
      name,
    ]);
    const matchingLine = registryOutput
      .split(/\r?\n/)
      .find((line) => line.trimStart().startsWith(name));
    return matchingLine?.split(/\s+REG_(?:EXPAND_)?SZ\s+/)[1]?.trim() || "";
  } catch {
    return "";
  }
}

function writeWindowsUserEnvironmentVariable(name, value, expandable = false) {
  if (readWindowsUserEnvironmentVariable(name) === value) return;
  executeCommand(
    "reg.exe",
    [
      "add",
      "HKCU\\Environment",
      "/v",
      name,
      "/t",
      expandable ? "REG_EXPAND_SZ" : "REG_SZ",
      "/d",
      value,
      "/f",
    ],
    { stdio: "ignore" },
  );
}

export function configureWindowsUserEnvironment() {
  const nvmHome = path.join(localDirectory, "opt", "nvm-windows");
  const activeNodeDirectory = path.join(nvmHome, "nodejs");
  process.env.NVM_HOME = nvmHome;
  process.env.NVM_SYMLINK = activeNodeDirectory;
  process.env.PATH = `${nvmHome};${activeNodeDirectory};${process.env.PATH || ""}`;

  fs.writeFileSync(
    path.join(nvmHome, "settings.txt"),
    `root: ${nvmHome}\r\npath: ${activeNodeDirectory}\r\narch: 64\r\nproxy: none\r\n`,
  );
  executeCommand(path.join(nvmHome, "nvm.exe"), ["use", versions.node]);

  const requiredPathEntries = [
    path.join(localDirectory, "bin"),
    path.join(localDirectory, "opt", "nvim", "bin"),
    path.join(localDirectory, "opt", "go", "bin"),
    nvmHome,
    activeNodeDirectory,
  ];
  const currentPathEntries = readWindowsUserEnvironmentVariable("Path")
    .split(";")
    .filter(Boolean);
  for (const requiredEntry of requiredPathEntries) {
    if (
      !currentPathEntries.some(
        (entry) => entry.toLowerCase() === requiredEntry.toLowerCase(),
      )
    ) {
      currentPathEntries.push(requiredEntry);
    }
  }
  writeWindowsUserEnvironmentVariable(
    "Path",
    currentPathEntries.join(";"),
    true,
  );
  writeWindowsUserEnvironmentVariable(
    "XDG_CONFIG_HOME",
    path.join(targetHome, ".config"),
  );
  writeWindowsUserEnvironmentVariable("NVM_HOME", nvmHome);
  writeWindowsUserEnvironmentVariable("NVM_SYMLINK", activeNodeDirectory);
}
