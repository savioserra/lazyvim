const implementations = {
  darwin: "./macos.mjs",
  linux: "./linux.mjs",
  win32: "./windows.mjs",
};

const implementationPath = implementations[process.platform];
if (!implementationPath) {
  throw new Error(`Unsupported platform: ${process.platform}`);
}

export const {
  configureFonts,
  configureNodeHost,
  configureRuntimeEnvironment,
  managedNeovimExecutable,
  managedNodeExecutable,
  managedToolExecutable,
  neovimDataDirectory,
  platformName,
  verifyFonts,
  verifyNodeHost,
} = await import(implementationPath);
