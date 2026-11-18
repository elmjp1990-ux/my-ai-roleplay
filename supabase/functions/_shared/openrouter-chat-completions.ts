import { normalizeAiProviderResult, type AiProviderResult } from "./ai-provider-result.ts";
import { buildOpenRouterProviderOptions } from "./openrouter-provider-policy.ts";

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
  responseParsed: boolean;
  rawResponseBody: string;
  rawOutputText: string;
  finishReason: string;
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
      provider: buildOpenRouterProviderOptions(),
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
      // Preserve the upstream HTTP status. The previous fallback always emitted
      // invalid_provider_response and hid useful 429/5xx diagnostics.
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
    const finishReason = asText(firstChoice.finish_reason || payload.finish_reason ||
      asRow(payload.incomplete_details).reason);
    return {
      result: normalizeAiProviderResult(payload),
      rawResponseBody: responseText.slice(0, 250000),
      rawOutputText,
      finishReason,
      httpStatus: response.status,
      requestId: response.headers.get("x-request-id") || asText(payload.id),
      provider: asText(payload.provider),
      model: asText(payload.model) || model,
      usage: asRow(payload.usage),
      responseContentType,
      responseBodyLength: responseText.length,
      responseParsed,
    };
  } finally {
    clearTimeout(timeout);
  }
}
