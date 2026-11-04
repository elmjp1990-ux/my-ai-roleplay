/**
 * Provider-neutral normalization for a single AI generation result.
 *
 * Only explicit provider safety/refusal signals are classified as
 * content_rejected. Empty output, rate limits, timeouts, and generic errors
 * must never be mislabeled as a content-policy refusal.
 */
export type AiProviderResult =
  | { kind: "generated"; text: string }
  | { kind: "content_rejected"; reason: "provider_refusal" }
  | { kind: "empty_output" }
  | { kind: "provider_error"; retryable: boolean; code: string };

type JsonObject = Record<string, unknown>;

const asObject = (value: unknown): JsonObject =>
  value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : {};

const asText = (value: unknown): string =>
  typeof value === "string" ? value.trim() : "";

const POLICY_CODES = new Set([
  "content_filter",
  "content_filtered",
  "content_policy_violation",
  "policy_violation",
  "safety_refusal",
  "refusal",
]);

function normalizedCode(value: unknown): string {
  return asText(value).toLowerCase().replace(/[\s-]+/g, "_");
}

function isExplicitPolicyCode(value: unknown): boolean {
  const code = normalizedCode(value);
  return POLICY_CODES.has(code) ||
    code.includes("content_policy") ||
    code.includes("content_filter");
}

function hasRefusalItem(value: unknown): boolean {
  if (!Array.isArray(value)) return false;
  return value.some((entry) => {
    const item = asObject(entry);
    if (normalizedCode(item.type) === "refusal") return true;
    if (isExplicitPolicyCode(item.type) || isExplicitPolicyCode(item.code)) return true;
    if (Array.isArray(item.content) && hasRefusalItem(item.content)) return true;
    return false;
  });
}

function extractText(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (!Array.isArray(value)) return "";
  return value.map((part) => {
    if (typeof part === "string") return part;
    const item = asObject(part);
    return asText(item.text) || asText(item.output_text);
  }).filter(Boolean).join("\n").trim();
}

function getGeneratedText(response: JsonObject): string {
  const direct = asText(response.output_text);
  if (direct) return direct;

  const choices = Array.isArray(response.choices) ? response.choices : [];
  const firstChoice = asObject(choices[0]);
  const message = asObject(firstChoice.message);
  const choiceText = extractText(message.content);
  if (choiceText) return choiceText;

  const output = Array.isArray(response.output) ? response.output : [];
  const chunks: string[] = [];
  for (const entry of output) {
    const item = asObject(entry);
    if (normalizedCode(item.type) === "message" && Array.isArray(item.content)) {
      for (const part of item.content) {
        const contentPart = asObject(part);
        const text = asText(contentPart.text) || asText(contentPart.output_text);
        if (text) chunks.push(text);
      }
    }
  }
  return chunks.join("\n").trim();
}

/**
 * Accepts an OpenAI-compatible Chat Completions or Responses envelope.
 * The adapter for a specific provider should normalize its response to this
 * shape before calling this function.
 */
export function normalizeAiProviderResult(value: unknown): AiProviderResult {
  const response = asObject(value);
  const error = asObject(response.error);
  const incomplete = asObject(response.incomplete_details);
  const choices = Array.isArray(response.choices) ? response.choices : [];
  const firstChoice = asObject(choices[0]);
  const message = asObject(firstChoice.message);

  const refusalText = asText(message.refusal);
  const explicitPolicySignal =
    Boolean(refusalText) ||
    isExplicitPolicyCode(firstChoice.finish_reason) ||
    isExplicitPolicyCode(response.finish_reason) ||
    isExplicitPolicyCode(incomplete.reason) ||
    isExplicitPolicyCode(error.code) ||
    isExplicitPolicyCode(error.type) ||
    hasRefusalItem(response.output) ||
    hasRefusalItem(message.annotations);

  if (explicitPolicySignal) {
    return { kind: "content_rejected", reason: "provider_refusal" };
  }

  if (response.error != null) {
    const status = Number(response.status);
    const code = normalizedCode(error.code || error.type || response.status || "provider_error");
    const retryable = status === 408 || status === 409 || status === 429 || status >= 500 ||
      code.includes("timeout") || code.includes("rate_limit") || code.includes("temporar");
    return { kind: "provider_error", retryable, code: code.slice(0, 80) };
  }

  const text = getGeneratedText(response);
  return text ? { kind: "generated", text } : { kind: "empty_output" };
}
