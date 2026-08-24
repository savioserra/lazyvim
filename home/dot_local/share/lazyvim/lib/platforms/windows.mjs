import fs from "node:fs";
import path from "node:path";
import { captureCommandOutput, executeCommand } from "../commands.mjs";
import { localDirectory, targetHome } from "../paths.mjs";
import { versions } from "../versions.mjs";

export const platformName = "win32";
const nvmDirectory = path.join(localDirectory, "opt", "nvm-windows");
const activeNodeDirectory = path.join(nvmDirectory, "nodejs");
const fontDirectory = path.join(
  process.env.LOCALAPPDATA || path.join(targetHome, "AppData", "Local"),
  "Microsoft",
  "Windows",
  "Fonts",
  "JetBrainsMonoNerdFont",
);

export const managedNodeExecutable = path.join(activeNodeDirectory, "node.exe");
export const managedNeovimExecutable = path.join(
  localDirectory,
  "opt",
  "nvim",
  "bin",
  "nvim.exe",
);
export const neovimDataDirectory = path.join(
  process.env.LOCALAPPDATA || path.join(targetHome, "AppData", "Local"),
  "nvim-data",
);

export function managedToolExecutable(name) {
  if (name === "go") {
    return path.join(localDirectory, "opt", "go", "bin", "go.exe");
  }
  return path.join(localDirectory, "bin", `${name}.exe`);
}

export function configureRuntimeEnvironment() {
  process.env.NVM_HOME = nvmDirectory;
  process.env.NVM_SYMLINK = activeNodeDirectory;
  process.env.PATH = [
    path.join(localDirectory, "bin"),
    path.join(localDirectory, "opt", "nvim", "bin"),
    path.join(localDirectory, "opt", "go", "bin"),
    nvmDirectory,
    activeNodeDirectory,
    process.env.PATH || "",
  ].join(";");
}

export function configureNodeHost() {
  configureRuntimeEnvironment();
  fs.writeFileSync(
    path.join(nvmDirectory, "settings.txt"),
    `root: ${nvmDirectory}\r\npath: ${activeNodeDirectory}\r\narch: 64\r\nproxy: none\r\n`,
  );
  executeCommand(path.join(nvmDirectory, "nvm.exe"), ["use", versions.node]);
  configureUserEnvironment();
}

export function configureFonts() {
  registerFonts();
}

export function verifyNodeHost() {
  if (
    captureCommandOutput(path.join(nvmDirectory, "nvm.exe"), ["version"]) !==
    versions.nvmWindows
  ) {
    throw new Error("Unexpected nvm-windows version");
  }
}

export function verifyFonts() {
  const installedFonts = fs
    .readdirSync(fontDirectory)
    .filter((name) => name.endsWith(".ttf"));
  if (installedFonts.length === 0) {
    throw new Error("No JetBrainsMono Nerd Font files were installed");
  }
  const registeredFonts = captureCommandOutput("reg.exe", [
    "query",
    "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
  ])
    .split(/\r?\n/)
    .filter((line) => line.toLowerCase().includes(fontDirectory.toLowerCase()));
  if (registeredFonts.length !== installedFonts.length) {
    throw new Error(
      `Expected ${installedFonts.length} registered fonts, got ${registeredFonts.length}`,
    );
  }
}

function readUserEnvironmentVariable(name) {
  try {
    const output = captureCommandOutput("reg.exe", [
      "query",
      "HKCU\\Environment",
      "/v",
      name,
    ]);
    const line = output
      .split(/\r?\n/)
      .find((candidate) => candidate.trimStart().startsWith(name));
    return line?.split(/\s+REG_(?:EXPAND_)?SZ\s+/)[1]?.trim() || "";
  } catch {
    return "";
  }
}

function writeUserEnvironmentVariable(name, value, expandable = false) {
  if (readUserEnvironmentVariable(name) === value) return;
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

function configureUserEnvironment() {
  const requiredPathEntries = [
    path.join(localDirectory, "bin"),
    path.join(localDirectory, "opt", "nvim", "bin"),
    path.join(localDirectory, "opt", "go", "bin"),
    nvmDirectory,
    activeNodeDirectory,
  ];
  const currentPathEntries = readUserEnvironmentVariable("Path")
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
  writeUserEnvironmentVariable("Path", currentPathEntries.join(";"), true);
  writeUserEnvironmentVariable(
    "XDG_CONFIG_HOME",
    path.join(targetHome, ".config"),
  );
  writeUserEnvironmentVariable("NVM_HOME", nvmDirectory);
  writeUserEnvironmentVariable("NVM_SYMLINK", activeNodeDirectory);
}

function registerFonts() {
  if (!fs.existsSync(fontDirectory)) return;
  const registryPath =
    "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts";
  const existingEntries = captureCommandOutput("reg.exe", [
    "query",
    registryPath,
  ]);
  for (const line of existingEntries.split(/\r?\n/)) {
    const match = line.match(/^\s{4}(.+?)\s+REG_SZ\s+(.+)$/);
    const managedEntry = match?.[2]
      .toLowerCase()
      .startsWith(fontDirectory.toLowerCase());
    const brokenLegacyEntry =
      match?.[1].startsWith("JetBrainsMono") && !/^[A-Za-z]:\\/.test(match[2]);
    if (managedEntry || brokenLegacyEntry) {
      executeCommand(
        "reg.exe",
        ["delete", registryPath, "/v", match[1], "/f"],
        {
          stdio: "ignore",
        },
      );
    }
  }
  for (const filename of fs
    .readdirSync(fontDirectory)
    .filter((name) => name.endsWith(".ttf"))) {
    executeCommand(
      "reg.exe",
      [
        "add",
        registryPath,
        "/v",
        `${path.parse(filename).name} (TrueType)`,
        "/t",
        "REG_SZ",
        "/d",
        path.join(fontDirectory, filename),
        "/f",
      ],
      { stdio: "ignore" },
    );
  }
  notifyFontConsumers();
}

function notifyFontConsumers() {
  const escapedDirectory = fontDirectory.replaceAll("'", "''");
  const script = `Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FontRegistration {
  [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResourceEx(string fileName, uint flags, IntPtr reserved);
  [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
}
'@
Get-ChildItem -LiteralPath '${escapedDirectory}' -Filter '*.ttf' | ForEach-Object { [void][FontRegistration]::AddFontResourceEx($_.FullName, 0, [IntPtr]::Zero) }
$result = [UIntPtr]::Zero
[void][FontRegistration]::SendMessageTimeout([IntPtr]0xffff, 0x001d, [UIntPtr]::Zero, [IntPtr]::Zero, 0x0002, 5000, [ref]$result)`;
  executeCommand(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", script],
    { stdio: "ignore" },
  );
}
