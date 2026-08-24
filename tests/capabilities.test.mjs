import assert from "node:assert/strict";
import test from "node:test";
import { createCapabilityRegistry } from "../home/dot_local/share/lazyvim/capabilities/registry.mjs";

function idsFor(platformName) {
  return createCapabilityRegistry({ platform: { platformName } }).ordered.map(({ id }) => id);
}

test("Windows omits unsupported tmux capability", () => {
  const ids = idsFor("win32");
  assert.ok(!ids.includes("tmux"));
  assert.ok(ids.includes("nvim"));
  assert.ok(ids.includes("language.typescript"));
});

test("Unix enables tmux after its foundation dependency", () => {
  const ids = idsFor("linux");
  assert.ok(ids.includes("tmux"));
  assert.ok(ids.indexOf("foundation") < ids.indexOf("tmux"));
});

test("languages enhance Neovim without making Neovim language-specific", () => {
  const registry = createCapabilityRegistry({ platform: { platformName: "linux" } });
  const enhancements = registry.enhancementsFor("nvim");
  const clients = enhancements.flatMap((item) => item.languageCases || []).map((item) => item.client);
  assert.ok(clients.includes("typescript-tools"));
  assert.ok(clients.includes("gopls"));
  assert.ok(enhancements.some((item) => item.formatterCases?.length));
});
