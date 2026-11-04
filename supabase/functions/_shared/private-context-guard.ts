const normalize = (value: string): string =>
  value.normalize("NFKC").toLocaleLowerCase().replace(/[\s\p{P}\p{S}]+/gu, "");

function flattenStrings(value: unknown, output: string[] = []): string[] {
  if (typeof value === "string") {
    const text = value.trim();
    if (text) output.push(text);
  } else if (Array.isArray(value)) {
    for (const item of value) flattenStrings(item, output);
  } else if (value && typeof value === "object") {
    for (const item of Object.values(value as Record<string, unknown>)) flattenStrings(item, output);
  }
  return output;
}

/** Returns only private values, never their contents, for server-side output screening. */
export function collectProtectedContext(privateInfo: unknown, personalityProfile: unknown): string[] {
  return [...new Set([...flattenStrings(privateInfo), ...flattenStrings(personalityProfile)])];
}

/**
 * Detects verbatim or near-verbatim disclosure of author-only context.
 * Short values are checked only as complete phrases to reduce false positives.
 * Long values are also checked for a 20-code-point contiguous excerpt.
 */
export function findPrivateContextLeak(output: unknown, protectedValues: string[]): boolean {
  if (typeof output !== "string" || !output.trim()) return false;
  const normalizedOutput = normalize(output);
  if (!normalizedOutput) return false;

  for (const rawValue of protectedValues) {
    const value = normalize(rawValue);
    if (value.length < 12) continue;
    if (normalizedOutput.includes(value)) return true;
    if (value.length >= 32) {
      for (let index = 0; index <= value.length - 20; index += 4) {
        if (normalizedOutput.includes(value.slice(index, index + 20))) return true;
      }
    }
  }
  return false;
}
