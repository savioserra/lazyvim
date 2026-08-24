export function defineCapability(definition) {
  if (!definition?.id || typeof definition.id !== "string") {
    throw new Error("A capability must have a string id");
  }
  return Object.freeze({
    requires: [],
    supports: () => true,
    enhancements: {},
    ...definition,
  });
}
