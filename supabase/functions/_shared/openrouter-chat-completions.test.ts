import { assertEquals, assertMatch } from "jsr:@std/assert";
import { buildOpenRouterProviderOptions } from "./openrouter-provider-policy.ts";
import { requestOpenRouterChatCompletion } from "./openrouter-chat-completions.ts";

Deno.test("shared OpenRouter transport applies model options, privacy policy and normalizes response metadata", async () => {
  const originalFetch = globalThis.fetch;
  let capturedUrl = "";
  let capturedInit: RequestInit | undefined;
  globalThis.fetch = async (input, init) => {
    capturedUrl = String(input);
    capturedInit = init;
    return new Response(JSON.stringify({
      id: "request-123",
      provider: "deepinfra",
      model: "openai/gpt-oss-20b",
      choices: [{ message: { content: "{\\"summary\\":\\"ok\\"}" } }],
      usage: { prompt_tokens: 12, completion_tokens: 8, total_tokens: 20 },
    }), {
      status: 200,
      headers: { "Content-Type": "application/json", "x-request-id": "gateway-123" },
    });
  };

  try {
    const result = await requestOpenRouterChatCompletion({
      messages: [{ role: "user", content: "summarize" }],
      apiKey: "test-key",
      model: "openai/gpt-oss-20b",
      timeoutMs: 45_000,
      temperature: 0.2,
      responseFormat: { type: "json_object" },
    });

    assertEquals(capturedUrl, "https://openrouter.ai/api/v1/chat/completions");
    assertEquals(capturedInit?.method, "POST");
    const headers = new Headers(capturedInit?.headers);
    assertEquals(headers.get("Authorization"), "Bearer test-key");
    const body = JSON.parse(String(capturedInit?.body));
    assertEquals(body.model, "openai/gpt-oss-20b");
    assertEquals(body.temperature, 0.2);
    assertEquals(body.response_format, { type: "json_object" });
    assertEquals(body.provider, buildOpenRouterProviderOptions());
    assertEquals(body.messages, [{ role: "user", content: "summarize" }]);
    assertEquals(result.result, { kind: "generated", text: "{\\"summary\\":\\"ok\\"}" });
    assertEquals(result.httpStatus, 200);
    assertEquals(result.requestId, "gateway-123");
    assertEquals(result.provider, "deepinfra");
    assertEquals(result.model, "openai/gpt-oss-20b");
    assertEquals(result.usage.total_tokens, 20);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
