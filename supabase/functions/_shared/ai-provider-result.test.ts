import { assertEquals } from "jsr:@std/assert";
import { normalizeAiProviderResult } from "./ai-provider-result.ts";

Deno.test("classifies Chat Completions content_filter as explicit content rejection", () => {
  assertEquals(normalizeAiProviderResult({
    choices: [{ finish_reason: "content_filter", message: { content: null } }],
  }), { kind: "content_rejected", reason: "provider_refusal" });
});

Deno.test("classifies explicit refusal field as content rejection", () => {
  assertEquals(normalizeAiProviderResult({
    choices: [{ finish_reason: "stop", message: { refusal: "I cannot help with that request." } }],
  }), { kind: "content_rejected", reason: "provider_refusal" });
});

Deno.test("classifies Responses API refusal output item as content rejection", () => {
  assertEquals(normalizeAiProviderResult({
    output: [{ type: "refusal", refusal: "I cannot help with that request." }],
  }), { kind: "content_rejected", reason: "provider_refusal" });
});

Deno.test("classifies Responses API refusal content part as content rejection", () => {
  assertEquals(normalizeAiProviderResult({
    output: [{ type: "message", content: [{ type: "refusal", refusal: "Blocked" }] }],
  }), { kind: "content_rejected", reason: "provider_refusal" });
});

Deno.test("does not misclassify an empty output as a content rejection", () => {
  assertEquals(normalizeAiProviderResult({
    choices: [{ finish_reason: "length", message: { content: "" } }],
  }), { kind: "empty_output" });
});

Deno.test("does not misclassify a rate limit as a content rejection", () => {
  assertEquals(normalizeAiProviderResult({
    status: 429,
    error: { code: "rate_limit_exceeded", message: "Too many requests" },
  }), { kind: "provider_error", retryable: true, code: "rate_limit_exceeded" });
});

Deno.test("does not misclassify a provider 5xx as a content rejection", () => {
  assertEquals(normalizeAiProviderResult({
    status: 503,
    error: { code: "server_error" },
  }), { kind: "provider_error", retryable: true, code: "server_error" });
});

Deno.test("extracts normal Chat Completions text", () => {
  assertEquals(normalizeAiProviderResult({
    choices: [{ finish_reason: "stop", message: { content: "  Hello there.  " } }],
  }), { kind: "generated", text: "Hello there." });
});

Deno.test("extracts normal Responses API output text", () => {
  assertEquals(normalizeAiProviderResult({
    output: [{ type: "message", content: [{ type: "output_text", text: "A reply." }] }],
  }), { kind: "generated", text: "A reply." });
});

Deno.test("classifies a Gateway HTTP 400 with explicit policy code as content rejection", () => {
  assertEquals(normalizeAiProviderResult({
    status: 400,
    error: { type: "content_policy_violation", message: "Request blocked by policy" },
  }), { kind: "content_rejected", reason: "provider_refusal" });
});

Deno.test("keeps Vercel no_providers_available as a generic provider error", () => {
  assertEquals(normalizeAiProviderResult({
    status: 400,
    error: {
      type: "no_providers_available",
      code: "no_providers_available",
    },
  }), {
    kind: "provider_error",
    retryable: false,
    code: "no_providers_available",
  });
});

Deno.test("does not classify generic HTTP 400 as content rejection", () => {
  assertEquals(normalizeAiProviderResult({
    status: 400,
    error: { code: "invalid_request_error", message: "Invalid parameter" },
  }), { kind: "provider_error", retryable: false, code: "invalid_request_error" });
});
