export const PROMPT_VARIABLE_KEYS = [
  "USER", "CHAR", "USER_DESC", "CHAR_DESC", "USER_GENDER", "USER_PRONOUN",
  "WORLD", "SETTING", "SCENE", "RELATIONSHIP", "TIME", "LOCATION",
  "USER_MESSAGE", "CHAT_HISTORY", "MEMORY", "SUMMARY", "TURN_COUNT", "CURRENT_DATE",
  "CHAR_LIST", "ACTIVE_CHAR", "OTHER_CHARS", "GROUP_NAME", "GROUP_WORLD", "GROUP_SCENE",
] as const;

export type PromptVariableKey = typeof PROMPT_VARIABLE_KEYS[number];
export type PromptVariableValues = Record<PromptVariableKey, string>;

const clean = (value: unknown): string => {
  if (value == null) return "";
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return "";
};

export function replacePromptVariables(template: unknown, values: Partial<Record<PromptVariableKey, unknown>>): string {
  return String(template ?? "").replace(/\{([A-Z][A-Z0-9_]*)\}/g, (literal, key: string) => {
    if (!(PROMPT_VARIABLE_KEYS as readonly string[]).includes(key)) return literal;
    const value = values[key as PromptVariableKey];
    return value == null ? "" : String(value);
  });
}

export function taipeiCurrentDate(now: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Taipei", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(now);
  const fields = Object.fromEntries(parts.map(part => [part.type, part.value]));
  return `${fields.year}-${fields.month}-${fields.day}`;
}

export function capMemory(value: unknown, maxLength = 3000): string {
  return clean(value).slice(0, Math.max(0, maxLength));
}
