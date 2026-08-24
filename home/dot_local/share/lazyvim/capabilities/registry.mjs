import foundation from "./foundation.mjs";
import fonts from "./fonts.mjs";
import go from "./languages/go.mjs";
import standardLanguages from "./languages/standard.mjs";
import typescript from "./languages/typescript.mjs";
import node from "./node.mjs";
import nvim from "./nvim.mjs";
import tmux from "./tmux.mjs";

const definitions = [
  foundation,
  fonts,
  node,
  nvim,
  tmux,
  go,
  typescript,
  standardLanguages,
];

export function createCapabilityRegistry(context) {
  const capabilities = new Map(definitions.map((item) => [item.id, item]));
  if (capabilities.size !== definitions.length) {
    throw new Error("Capability ids must be unique");
  }
  for (const capability of capabilities.values()) {
    for (const dependency of capability.requires) {
      if (!capabilities.has(dependency)) {
        throw new Error(
          `${capability.id} requires unknown capability ${dependency}`,
        );
      }
    }
  }

  const enabled = new Set(
    definitions.filter((item) => item.supports(context)).map((item) => item.id),
  );
  const visiting = new Set();
  const visited = new Set();
  const ordered = [];
  function visit(id) {
    if (!enabled.has(id) || visited.has(id)) return;
    if (visiting.has(id))
      throw new Error(`Capability dependency cycle at ${id}`);
    visiting.add(id);
    for (const dependency of capabilities.get(id).requires) {
      if (!enabled.has(dependency)) {
        throw new Error(`${id} requires unsupported capability ${dependency}`);
      }
      visit(dependency);
    }
    visiting.delete(id);
    visited.add(id);
    ordered.push(capabilities.get(id));
  }
  for (const id of enabled) visit(id);

  function enhancementsFor(target) {
    return ordered.flatMap(
      (capability) => capability.enhancements[target] || [],
    );
  }

  async function run(lifecycle) {
    for (const capability of ordered) {
      const hook = capability[lifecycle];
      if (!hook) continue;
      console.log(`\n==> ${lifecycle} capability: ${capability.id}`);
      await hook({ ...context, enhancements: enhancementsFor(capability.id) });
    }
  }

  return Object.freeze({ enhancementsFor, ordered, run });
}
