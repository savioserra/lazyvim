const SENSITIVE = /\b(?:raw[-_ ]*)?(principal|session|credential|pid|handle|fence|runtime|generation|token|secret)(?:[-_:=]?[A-Za-z0-9_.:/-]*)?/gi;
const CONTROL = /[\0\r\t\u001b\u202a-\u202e\u2066-\u2069]/g;

export function sanitizeText(value: unknown, max = 240): string {
  if (value instanceof Uint8Array) value = new TextDecoder("utf-8", { fatal: false }).decode(value);
  const text = typeof value === "string" ? value : value == null ? "" : String(value);
  const clean = text.replace(CONTROL, " ").replace(/\n{3,}/g, "\n\n").replace(SENSITIVE, "[redacted]").replace(/[ \f\v]+/g, " ").trim();
  return clean.length > max ? `${clean.slice(0, Math.max(0, max - 1))}…` : clean;
}

export function sanitizeLabel(value: unknown, max = 64): string | undefined {
  const clean = sanitizeText(value, max).replace(/[^\p{L}\p{N} .:_+\-\[\]]/gu, " ").replace(/\s+/g, " ").trim();
  return clean || undefined;
}

export function naturalRole(value: unknown, max = 32): string | undefined {
  const clean = sanitizeLabel(value, max);
  if (!clean) return undefined;
  return clean === clean.toLocaleUpperCase() ? clean.toLocaleLowerCase().replaceAll("_", " ") : clean;
}
