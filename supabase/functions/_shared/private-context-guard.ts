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
 * Keep the prompt context bounded while screening against the complete source.
 * Never truncate author-only source material before building the leak detector.
 */
export function preparePrivateContext(
  privateInfo: unknown,
  personalityProfile: unknown,
  promptLimit = 6000,
): { promptText: string; protectedValues: string[] } {
  const fullPrivateInfo = typeof privateInfo === "string" ? privateInfo : "";
  return {
    promptText: fullPrivateInfo.slice(0, Math.max(0, promptLimit)),
    protectedValues: collectProtectedContext(fullPrivateInfo, personalityProfile),
  };
}

/**
 * Detects verbatim or near-verbatim disclosure of author-only context.
 * Short values are ignored to reduce false positives from ordinary character traits.
 * Long values are checked for a 32-code-point contiguous excerpt.
 */
const base64Utf8 = (value: string): string => {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
};

export function findPrivateContextLeak(
  output: unknown,
  protectedValues: string[],
  priorOutputs: string[] = [],
): boolean {
  if (typeof output !== "string" || !output.trim()) return false;
  // Check a short rolling window of earlier assistant turns together with the
  // current response, so a secret cannot be disclosed as individually small fragments.
  const combinedOutput = [...priorOutputs, output].filter((part) => typeof part === "string").join("\n");
  const normalizedOutput = normalize(combinedOutput);
  const rawOutput = combinedOutput.normalize("NFKC").toLocaleLowerCase();
  if (!normalizedOutput) return false;

  for (const rawValue of protectedValues) {
    const value = normalize(rawValue);
    if (value.length < 12) continue;
    if (normalizedOutput.includes(value)) return true;

    // Catch common direct transformations used to disguise copied settings.
    const raw = rawValue.normalize("NFKC");
    const encodedForms = [
      encodeURIComponent(rawValue).toLocaleLowerCase(),
      encodeURIComponent(raw).toLocaleLowerCase(),
      base64Utf8(rawValue).toLocaleLowerCase(),
      base64Utf8(raw).toLocaleLowerCase(),
      base64Utf8(value).toLocaleLowerCase(),
    ];
    if (encodedForms.some((encoded) => encoded.length >= 24 && rawOutput.includes(encoded))) {
      return true;
    }

    // Also check encoded long excerpts, not only the full setting.
    if (value.length >= 48) {
      for (let index = 0; index <= value.length - 32; index += 4) {
        const excerpt = value.slice(index, index + 32);
        if (normalizedOutput.includes(excerpt)) return true;
        const encodedExcerpt = base64Utf8(excerpt).toLocaleLowerCase();
        if (rawOutput.includes(encodedExcerpt)) return true;
      }
    }
  }
  return false;
}
