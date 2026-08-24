import fs from "node:fs";
import path from "node:path";

const targetHome =
  process.env.CHEZMOI_DESTDIR || process.env.HOME || process.env.USERPROFILE;
if (!targetHome)
  throw new Error("Unable to determine the target home directory");

export const NODE_VERSION = fs
  .readFileSync(path.join(targetHome, ".node-version"), "utf8")
  .trim();

export const TMUX_PLUGINS = Object.freeze([
  [
    "tpm",
    "https://github.com/tmux-plugins/tpm.git",
    "e261deb1b47614eed3400089ce7197dc68acc4eb",
  ],
  [
    "tmux2k",
    "https://github.com/2KAbhishek/tmux2k.git",
    "07b3228b56c1a7b6109f00009df80b53f7eae892",
  ],
  [
    "tmux-yank",
    "https://github.com/tmux-plugins/tmux-yank.git",
    "acfd36e4fcba99f8310a7dfb432111c242fe7392",
  ],
  [
    "vim-tmux-navigator",
    "https://github.com/christoomey/vim-tmux-navigator.git",
    "e41c431a0c7b7388ae7ba341f01a0d217eb3a432",
  ],
  [
    "tmux-resurrect",
    "https://github.com/tmux-plugins/tmux-resurrect.git",
    "cff343cf9e81983d3da0c8562b01616f12e8d548",
  ],
]);
