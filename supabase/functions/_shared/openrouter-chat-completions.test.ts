import { assertEquals } from "jsr:@std/assert";
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
      choices: [{ message: { content: '{"summary":"ok"}' } }],
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
    assertEquals(result.result, { kind: "generated", text: '{"summary":"ok"}' });
    assertEquals(result.httpStatus, 200);
    assertEquals(result.requestId, "gateway-123");
    assertEquals(result.provider, "deepinfra");
    assertEquals(result.model, "openai/gpt-oss-20b");
    assertEquals(result.usage.total_tokens, 20);
    assertEquals(JSON.parse(result.rawResponseBody).choices[0].message.content, '{"summary":"ok"}');
  } finally {
    globalThis.fetch = originalFetch;
  }
});


Deno.test("transient DeepInfra failures retry once through Inference.net without widening provider policy", async () => {
  const originalFetch = globalThis.fetch;
  const capturedBodies: Record<string, unknown>[] = [];
  let call = 0;
  globalThis.fetch = async (_input, init) => {
    call += 1;
    capturedBodies.push(JSON.parse(String(init?.body)));
    if (call === 1) {
      return new Response(JSON.stringify({
        error: { code: "engine_overloaded", message: "upstream provider is overloaded" },
      }), {
        status: 429,
        headers: { "Content-Type": "application/json", "x-request-id": "deepinfra-429" },
      });
    }
    return new Response(JSON.stringify({
      id: "inference-request",
      provider: "inference-net",
      model: "deepseek/deepseek-v4-flash-20260423",
      choices: [{ message: { content: "備援供應商正常回覆" } }],
      usage: { prompt_tokens: 10, completion_tokens: 12, total_tokens: 22 },
    }), {
      status: 200,
      headers: { "Content-Type": "application/json", "x-request-id": "inference-200" },
    });
  };

  try {
    const result = await requestOpenRouterChatCompletion({
      messages: [{ role: "user", content: "test fallback" }],
      apiKey: "test-key",
      timeoutMs: 1_000,
    });

    assertEquals(call, 2);
    assertEquals(capturedBodies.map((body) => body.provider), [
      { only: ["deepinfra"], allow_fallbacks: false, data_collection: "allow" },
      { only: ["inference-net"], allow_fallbacks: false, data_collection: "allow" },
    ]);
    assertEquals(capturedBodies[0].model, "deepseek/deepseek-v4-flash-20260423");
    assertEquals(capturedBodies[1].model, "deepseek/deepseek-v4-flash-20260423");
    assertEquals(result.result, { kind: "generated", text: "備援供應商正常回覆" });
    assertEquals(result.provider, "inference-net");
    assertEquals(result.requestId, "inference-200");
    assertEquals(result.usage.total_tokens, 22);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("non-transient provider errors do not switch providers", async () => {
  const originalFetch = globalThis.fetch;
  let call = 0;
  globalThis.fetch = async (_input, init) => {
    call += 1;
    const body = JSON.parse(String(init?.body));
    assertEquals(body.provider.only, ["deepinfra"]);
    return new Response(JSON.stringify({
      error: { code: "invalid_request", message: "invalid request" },
    }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  };

  try {
    const result = await requestOpenRouterChatCompletion({
      messages: [{ role: "user", content: "invalid request test" }],
      apiKey: "test-key",
      timeoutMs: 1_000,
    });
    assertEquals(call, 1);
    assertEquals(result.result.kind, "provider_error");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("content refusals do not switch providers", async () => {
  const originalFetch = globalThis.fetch;
  let call = 0;
  globalThis.fetch = async (_input, init) => {
    call += 1;
    const body = JSON.parse(String(init?.body));
    assertEquals(body.provider.only, ["deepinfra"]);
    return new Response(JSON.stringify({
      provider: "deepinfra",
      choices: [{ message: { refusal: "blocked by provider policy", content: "" }, finish_reason: "stop" }],
    }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };

  try {
    const result = await requestOpenRouterChatCompletion({
      messages: [{ role: "user", content: "refusal test" }],
      apiKey: "test-key",
      timeoutMs: 1_000,
    });
    assertEquals(call, 1);
    assertEquals(result.result, { kind: "content_rejected", reason: "provider_refusal" });
    assertEquals(result.rawRefusalText, "blocked by provider policy");
    assertEquals(result.rawResponseBody.includes("blocked by provider policy"), true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});


Deno.test("ambiguous generic 5xx provider outcomes do not trigger a second billed request", async () => {
  const originalFetch = globalThis.fetch;
  let call = 0;
  globalThis.fetch = async (_input, init) => {
    call += 1;
    const body = JSON.parse(String(init?.body));
    assertEquals(body.provider.only, ["deepinfra"]);
    return new Response(JSON.stringify({
      error: { code: "http_503", message: "upstream response unavailable" },
    }), {
      status: 503,
      headers: { "Content-Type": "application/json" },
    });
  };

  try {
    const result = await requestOpenRouterChatCompletion({
      messages: [{ role: "user", content: "ambiguous 503 test" }],
      apiKey: "test-key",
      timeoutMs: 1_000,
    });
    assertEquals(call, 1);
    assertEquals(result.httpStatus, 503);
    assertEquals(result.result.kind, "provider_error");
  } finally {
    globalThis.fetch = originalFetch;
  }
});


Deno.test("GPT OSS summary routing stays on approved DeepInfra when Inference.net does not serve the model", async () => {
  const originalFetch = globalThis.fetch;
  let call = 0;
  let capturedProvider: unknown = null;
  globalThis.fetch = async (_input, init) => {
    call += 1;
    capturedProvider = JSON.parse(String(init?.body)).provider;
    return new Response(JSON.stringify({ error: { code: "engine_overloaded", message: "temporary provider capacity issue" } }), {
      status: 429, headers: { "Content-Type": "application/json" },
    });
  };
  try {
    const result = await requestOpenRouterChatCompletion({
      messages: [{ role: "user", content: "summarize" }],
      apiKey: "test-key", model: "openai/gpt-oss-20b",
      provider: "deepinfra", disableProviderFallback: true, timeoutMs: 1_000,
    });
    assertEquals(call, 1);
    assertEquals(capturedProvider, { only: ["deepinfra"], allow_fallbacks: false, data_collection: "allow" });
    assertEquals(result.httpStatus, 429);
  } finally { globalThis.fetch = originalFetch; }
});
