import { normalizeAiProviderResult, type AiProviderResult } from "./ai-provider-result.ts";
import {
  APPROVED_OPENROUTER_PROVIDERS,
  buildOpenRouterProviderOptions,
  type ApprovedOpenRouterProvider,
} from "./openrouter-provider-policy.ts";

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
  responseContentType: string;
  responseBodyLength: number;
  durationMs: number;
  responseParsed: boolean;
  rawResponseBody: string;
  rawOutputText: string;
  rawRefusalText: string;
  finishReason: string;
};

type RequestOptions = {
  messages: OpenRouterChatMessage[];
  apiKey: string;
  model?: string;
  timeoutMs?: number;
  temperature?: number;
  responseFormat?: { type: "json_object" };
  provider?: ApprovedOpenRouterProvider;
  disableProviderFallback?: boolean;
};

const asRow = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
const asText = (value: unknown): string => typeof value === "string" ? value.trim() : "";

function isTransientProviderFailure(response: OpenRouterCompletionResult): boolean {
  // Retry explicit rate limits immediately. Generic 5xx/timeouts are not
  // retried because the upstream billing outcome can be ambiguous.
  if (response.httpStatus === 429) return true;
  if (response.result.kind !== "provider_error") return false;
  const errorCode = response.result.code;
  return [
    "engine_overloaded",
    "upstream_overloaded",
    "upstream_unavailable",
    "provider_overloaded",
    "capacity_exceeded",
    "rate_limit",
    "temporarily_unavailable",
    "upstream_busy",
  ].some((code) => errorCode.includes(code));
}

async function requestFromProvider(
  options: RequestOptions,
  model: string,
  provider: ApprovedOpenRouterProvider,
): Promise<OpenRouterCompletionResult> {
  const startedAt = Date.now();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs ?? 55_000);
  try {
    const body: Record<string, unknown> = {
      model,
      messages: options.messages,
      temperature: options.temperature ?? 0.85,
      provider: buildOpenRouterProviderOptions(provider),
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
    const responseContentType = response.headers.get("content-type") || "";
    const responseText = await response.text();
    let payload: Record<string, unknown>;
    let responseParsed = true;
    try {
      payload = asRow(JSON.parse(responseText));
    } catch {
      responseParsed = false;
      // Preserve the upstream HTTP status so transient HTTP failures remain identifiable.
      payload = {
        error: {
          code: response.ok ? "invalid_provider_response" : "http_" + response.status,
        },
      };
    }
    payload.status = response.status;
    if (!response.ok && payload.error == null) payload.error = { code: "http_" + response.status };
    const choices = Array.isArray(payload.choices) ? payload.choices : [];
    const firstChoice = asRow(choices[0]);
    const message = asRow(firstChoice.message);
    const rawContent = typeof message.content === "string" ? message.content :
      Array.isArray(message.content) ? message.content.map((part) => {
        const item = asRow(part);
        return typeof item.text === "string" ? item.text : "";
      }).join("\\n") : "";
    const rawOutputText = rawContent || (typeof payload.output_text === "string" ? payload.output_text : "");
    const rawRefusalText = asText(message.refusal) || (Array.isArray(message.annotations)
      ? message.annotations.map((item) => asRow(item)).map((item) => asText(item.refusal || item.text)).filter(Boolean).join("\\n")
      : "");
    const finishReason = asText(firstChoice.finish_reason || payload.finish_reason ||
      asRow(payload.incomplete_details).reason);
    return {
      result: normalizeAiProviderResult(payload),
      rawResponseBody: responseText.slice(0, 250000),
      rawOutputText,
      rawRefusalText,
      finishReason,
      httpStatus: response.status,
      requestId: response.headers.get("x-request-id") || asText(payload.id),
      provider: asText(payload.provider) || provider,
      model: asText(payload.model) || model,
      usage: asRow(payload.usage),
      responseContentType,
      responseBodyLength: responseText.length,
      durationMs: Date.now() - startedAt,
      responseParsed,
    };
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Shared OpenRouter request path. Retry once on the second approved provider
 * only for explicit transient provider failures; safety refusals and ordinary
 * request errors never trigger a provider switch.
 */
export async function requestOpenRouterChatCompletion(options: RequestOptions): Promise<OpenRouterCompletionResult> {
  const model = options.model || POYOZZ_DEFAULT_CHAT_MODEL;
  const [defaultPrimaryProvider, defaultFallbackProvider] = APPROVED_OPENROUTER_PROVIDERS;
  const primaryProvider = options.provider || defaultPrimaryProvider;
  const primary = await requestFromProvider(options, model, primaryProvider);
  if (options.disableProviderFallback || !isTransientProviderFailure(primary)) return primary;
  const fallbackProvider = primaryProvider === defaultPrimaryProvider ? defaultFallbackProvider : defaultPrimaryProvider;
  return await requestFromProvider(options, model, fallbackProvider);
}
