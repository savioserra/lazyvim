import fs from "node:fs";
import path from "node:path";
import { NODE_VERSION, TMUX_PLUGINS } from "./lib/constants.mjs";
import { output, run } from "./lib/process.mjs";
import { home, isLinux, isWindows, local } from "./lib/paths.mjs";

function configureUnixNode() {
  const aliasDirectory = path.join(local, "opt", "nvm", "alias");
  fs.mkdirSync(aliasDirectory, { recursive: true });
  fs.writeFileSync(path.join(aliasDirectory, "default"), `${NODE_VERSION}\n`);
}

function installTmuxPlugins() {
  const pluginsDirectory = path.join(home, ".tmux", "plugins");
  fs.mkdirSync(pluginsDirectory, { recursive: true });
  fs.rmSync(path.join(pluginsDirectory, "tmux-fingers"), {
    recursive: true,
    force: true,
  });

  for (const [name, url, commit] of TMUX_PLUGINS) {
    const directory = path.join(pluginsDirectory, name);
    if (!fs.existsSync(path.join(directory, ".git"))) {
      run("git", ["clone", "--quiet", url, directory]);
    }
    const fetch = () =>
      run("git", ["-C", directory, "fetch", "--quiet", "origin", commit]);
    try {
      fetch();
    } catch {
      // The commit may already exist locally while a host is temporarily offline.
    }
    run("git", ["-C", directory, "checkout", "--quiet", commit]);
  }
}

function readUserEnvironment(name) {
  try {
    const result = output("reg.exe", [
      "query",
      "HKCU\\Environment",
      "/v",
      name,
    ]);
    const line = result
      .split(/\r?\n/)
      .find((value) => value.trimStart().startsWith(name));
    return line?.split(/\s+REG_(?:EXPAND_)?SZ\s+/)[1]?.trim() || "";
  } catch {
    return "";
  }
}

function setUserEnvironment(name, value, expandable = false) {
  if (readUserEnvironment(name) === value) return;
  run(
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

function configureWindowsEnvironment() {
  const nvmHome = path.join(local, "opt", "nvm-windows");
  const nvmSymlink = path.join(nvmHome, "nodejs");
  process.env.NVM_HOME = nvmHome;
  process.env.NVM_SYMLINK = nvmSymlink;
  process.env.PATH = `${nvmHome};${nvmSymlink};${process.env.PATH || ""}`;
  fs.writeFileSync(
    path.join(nvmHome, "settings.txt"),
    `root: ${nvmHome}\r\npath: ${nvmSymlink}\r\narch: 64\r\nproxy: none\r\n`,
  );
  run(path.join(nvmHome, "nvm.exe"), ["use", NODE_VERSION]);
  const required = [
    path.join(local, "bin"),
    path.join(local, "opt", "nvim", "bin"),
    path.join(local, "opt", "go", "bin"),
    nvmHome,
    nvmSymlink,
  ];
  const parts = readUserEnvironment("Path").split(";").filter(Boolean);
  for (const entry of required) {
    if (!parts.some((current) => current.toLowerCase() === entry.toLowerCase()))
      parts.push(entry);
  }
  setUserEnvironment("Path", parts.join(";"), true);
  setUserEnvironment("XDG_CONFIG_HOME", path.join(home, ".config"));
  setUserEnvironment("NVM_HOME", nvmHome);
  setUserEnvironment("NVM_SYMLINK", nvmSymlink);
}

function registerWindowsFonts() {
  const fontsDirectory = path.join(
    process.env.LOCALAPPDATA || path.join(home, "AppData", "Local"),
    "Microsoft",
    "Windows",
    "Fonts",
    "JetBrainsMonoNerdFont",
  );
  if (!fs.existsSync(fontsDirectory)) return;
  const registryPath =
    "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts";
  const existing = output("reg.exe", ["query", registryPath]);
  for (const line of existing.split(/\r?\n/)) {
    const match = line.match(/^\s{4}(.+?)\s+REG_SZ\s+(.+)$/);
    const managedPath = match?.[2]
      .toLowerCase()
      .startsWith(fontsDirectory.toLowerCase());
    const brokenLegacyEntry =
      match?.[1].startsWith("JetBrainsMono") && !/^[A-Za-z]:\\/.test(match[2]);
    if (managedPath || brokenLegacyEntry) {
      run("reg.exe", ["delete", registryPath, "/v", match[1], "/f"], {
        stdio: "ignore",
      });
    }
  }
  for (const filename of fs
    .readdirSync(fontsDirectory)
    .filter((name) => name.endsWith(".ttf"))) {
    run(
      "reg.exe",
      [
        "add",
        registryPath,
        "/v",
        `${path.parse(filename).name} (TrueType)`,
        "/t",
        "REG_SZ",
        "/d",
        path.join(fontsDirectory, filename),
        "/f",
      ],
      { stdio: "ignore" },
    );
  }

  const escapedDirectory = fontsDirectory.replaceAll("'", "''");
  const refreshScript = `
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FontRegistration {
  [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
  public static extern int AddFontResourceEx(string fileName, uint flags, IntPtr reserved);
  [DllImport("user32.dll", SetLastError = true)]
  public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
}
'@
Get-ChildItem -LiteralPath '${escapedDirectory}' -Filter '*.ttf' | ForEach-Object { [void][FontRegistration]::AddFontResourceEx($_.FullName, 0, [IntPtr]::Zero) }
$result = [UIntPtr]::Zero
[void][FontRegistration]::SendMessageTimeout([IntPtr]0xffff, 0x001d, [UIntPtr]::Zero, [IntPtr]::Zero, 0x0002, 5000, [ref]$result)
`;
  run(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", refreshScript],
    { stdio: "ignore" },
  );
}

if (isWindows) {
  configureWindowsEnvironment();
  registerWindowsFonts();
} else {
  configureUnixNode();
  installTmuxPlugins();
  if (isLinux) {
    try {
      run("fc-cache", ["-f", path.join(local, "share", "fonts")]);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
}
