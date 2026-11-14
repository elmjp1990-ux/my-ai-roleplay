/** Shared, side-effect-free value guards for POYOZZ Edge Functions. */
export type AiDbRow = Record<string, unknown>;

export const asRecord = (value: unknown): AiDbRow =>
  value && typeof value === "object" && !Array.isArray(value)
    ? value as AiDbRow
    : {};

export const asTrimmedString = (value: unknown): string =>
  typeof value === "string" ? value.trim() : "";

export const isUuid = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
