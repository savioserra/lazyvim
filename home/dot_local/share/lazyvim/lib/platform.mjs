export const platform = Object.freeze({
  isLinux: process.platform === "linux",
  isMacOS: process.platform === "darwin",
  isWindows: process.platform === "win32",
  name: process.platform,
});
