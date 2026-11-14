import { assertEquals, assertExists } from "jsr:@std/assert";
import { requestOpenRouterChatCompletion } from "./openrouter-chat-completions.ts";

Deno.test("shared OpenRouter transport preserves privacy, response format and usage metadata", async () => {
  const originalFetch = globalThis.fetch;
  let requestUrl = "";
  let requestInit: RequestInit | undefined;
  globalThis.fetch = async (input, init) => {
    requestUrl = String(input);
    requestInit = init;
    return new Response(JSON.stringify({
      id: "req_test_123",
      provider: "deepinfra",
      model: "openai/gpt-oss-20b",
      choices: [{ finish_reason: "stop", message: { content: "{\\"summary\\":\\"short\\"}" } }],
      usage: { prompt_tokens: 12, completion_tokens: 4, total_tokens: 16, cost: 0.0001 },
    }), {
      status: 200,
      headers: { "Content-Type": "application/json", "x-request-id": "req_header_123" },
    });
  };
  try {
    const result = await requestOpenRouterChatCompletion({
      messages: [{ role: "system", content: "Summarize." }, { role: "user", content: "Transcript." }],
      apiKey: "test-key",
      model: "openai/gpt-oss-20b",
      timeoutMs: 45_000,
      temperature: 0.2,
      responseFormat: { type: "json_object" },
    });
    assertEquals(requestUrl, "https://openrouter.ai/api/v1/chat/completions");
    assertExists(requestInit);
    const headers = new Headers(requestInit.headers);
    assertEquals(headers.get("Authorization"), "Bearer test-key");
    const body = JSON.parse(String(requestInit.body));
    assertEquals(body.model, "openai/gpt-oss-20b");
    assertEquals(body.temperature, 0.2);
    assertEquals(body.response_format, { type: "json_object" });
    assertEquals(body.provider, {
      only: ["deepinfra"], allow_fallbacks: false, data_collection: "deny",
    });
    assertEquals("max_tokens" in body, false);
    assertEquals(result.result, { kind: "generated", text: "{\\"summary\\":\\"short\\"}" });
    assertEquals(result.httpStatus, 200);
    assertEquals(result.requestId, "req_header_123");
    assertEquals(result.provider, "deepinfra");
    assertEquals(result.usage.total_tokens, 16);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
