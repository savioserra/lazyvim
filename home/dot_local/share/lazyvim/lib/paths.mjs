import path from "node:path";

export const targetHome =
  process.env.CHEZMOI_DESTDIR || process.env.HOME || process.env.USERPROFILE;
if (!targetHome)
  throw new Error("Unable to determine the target home directory");

export const localDirectory = path.join(targetHome, ".local");
