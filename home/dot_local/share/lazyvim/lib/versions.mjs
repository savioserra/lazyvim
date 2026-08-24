import fs from "node:fs";
import path from "node:path";

const targetHome =
  process.env.CHEZMOI_DESTDIR || process.env.HOME || process.env.USERPROFILE;
if (!targetHome)
  throw new Error("Unable to determine the target home directory");

export const versions = Object.freeze({
  fdMajor: "10",
  fzf: "0.74.2",
  go: "1.27.0",
  lazygit: "0.63.1",
  neovim: "0.12.4",
  node: fs.readFileSync(path.join(targetHome, ".node-version"), "utf8").trim(),
  nvmWindows: "1.2.2",
  ripgrep: "15.2.0",
  treeSitter: "0.26.11",
});
