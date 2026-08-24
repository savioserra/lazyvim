import fs from "node:fs";
import path from "node:path";
import { captureCommandOutput, executeCommand } from "./commands.mjs";
import { localDirectory, targetHome } from "./paths.mjs";

export function refreshLinuxFontCache() {
  try {
    executeCommand("fc-cache", [
      "-f",
      path.join(localDirectory, "share", "fonts"),
    ]);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

export function windowsFontDirectory() {
  return path.join(
    process.env.LOCALAPPDATA || path.join(targetHome, "AppData", "Local"),
    "Microsoft",
    "Windows",
    "Fonts",
    "JetBrainsMonoNerdFont",
  );
}

export function registerWindowsFonts() {
  const fontDirectory = windowsFontDirectory();
  if (!fs.existsSync(fontDirectory)) return;
  const registryPath =
    "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts";
  const existingEntries = captureCommandOutput("reg.exe", [
    "query",
    registryPath,
  ]);
  for (const line of existingEntries.split(/\r?\n/)) {
    const match = line.match(/^\s{4}(.+?)\s+REG_SZ\s+(.+)$/);
    const pointsIntoManagedDirectory = match?.[2]
      .toLowerCase()
      .startsWith(fontDirectory.toLowerCase());
    const isBrokenLegacyEntry =
      match?.[1].startsWith("JetBrainsMono") && !/^[A-Za-z]:\\/.test(match[2]);
    if (pointsIntoManagedDirectory || isBrokenLegacyEntry) {
      executeCommand(
        "reg.exe",
        ["delete", registryPath, "/v", match[1], "/f"],
        {
          stdio: "ignore",
        },
      );
    }
  }

  const fontFiles = fs
    .readdirSync(fontDirectory)
    .filter((name) => name.endsWith(".ttf"));
  for (const filename of fontFiles) {
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
  notifyWindowsAboutFontChanges(fontDirectory);
}

function notifyWindowsAboutFontChanges(fontDirectory) {
  const escapedDirectory = fontDirectory.replaceAll("'", "''");
  const script = `
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
  executeCommand(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", script],
    {
      stdio: "ignore",
    },
  );
}
