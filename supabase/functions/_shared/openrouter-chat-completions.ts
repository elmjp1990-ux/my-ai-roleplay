import { normalizeAiProviderResult, type AiProviderResult } from "./ai-provider-result.ts";

export const POYOZZ_DEFAULT_CHAT_MODEL = "deepseek/deepseek-v4-flash-20260423";

export type OpenRouterChatMessage = {
  role: "system" | "user" | "assistant";
  content: string;
};

export type OpenRouterCompletionResult = {
  result: AiProviderResult;
  httpStatus: number;
  requestId: string;
  provider: string;
  model: string;
  usage: Record<string, unknown>;
};

type RequestOptions = {
  messages: OpenRouterChatMessage[];
  apiKey: string;
  model?: string;
  timeoutMs?: number;
  temperature?: number;
  responseFormat?: { type: "json_object" };
};

const asRow = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
const asText = (value: unknown): string => typeof value === "string" ? value.trim() : "";

/** Shared OpenRouter request path; provider privacy restrictions cannot drift between chat modes. */
export async function requestOpenRouterChatCompletion(options: RequestOptions): Promise<OpenRouterCompletionResult> {
  const model = options.model || POYOZZ_DEFAULT_CHAT_MODEL;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs ?? 55_000);
  try {
    const body: Record<string, unknown> = {
      model,
      messages: options.messages,
      temperature: options.temperature ?? 0.85,
      provider: { only: ["deepinfra"], allow_fallbacks: false, data_collection: "deny" },
    };
    if (options.responseFormat) body.response_format = options.responseFormat;

    const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + options.apiKey,
        "Content-Type": "application/json",
        "X-OpenRouter-Title": "POYOZZ",
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    let payload = asRow(await response.json().catch(() => ({ error: { code: "invalid_provider_response" } })));
    payload.status = response.status;
    if (!response.ok && payload.error == null) payload.error = { code: "http_" + response.status };
    return {
      result: normalizeAiProviderResult(payload),
      httpStatus: response.status,
      requestId: response.headers.get("x-request-id") || asText(payload.id),
      provider: asText(payload.provider),
      model: asText(payload.model) || model,
      usage: asRow(payload.usage),
    };
  } finally {
    clearTimeout(timeout);
  }
}
