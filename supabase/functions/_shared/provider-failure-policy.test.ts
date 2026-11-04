import { assertEquals } from "jsr:@std/assert";
import type { AiProviderResult } from "./ai-provider-result.ts";
import { classifyProviderFailure } from "./provider-failure-policy.ts";

const providerError = (retryable: boolean): Extract<AiProviderResult, {kind:"provider_error"}> => ({
  kind: "provider_error",
  retryable,
  code: "test_error",
});

Deno.test("only an explicit HTTP 429 permits retrying the same reserved turn", () => {
  assertEquals(classifyProviderFailure(providerError(true), 429), "retry_same_turn");
});

Deno.test("HTTP 408 timeout remains locked for reconciliation", () => {
  assertEquals(classifyProviderFailure(providerError(true), 408), "reconcile");
});

Deno.test("retryable HTTP 409 remains locked for reconciliation", () => {
  assertEquals(classifyProviderFailure(providerError(true), 409), "reconcile");
});

Deno.test("retryable provider 5xx remains locked for reconciliation", () => {
  assertEquals(classifyProviderFailure(providerError(true), 503), "reconcile");
});

Deno.test("empty HTTP 200 output is ambiguous and must not trigger another generation", () => {
  assertEquals(classifyProviderFailure({kind:"empty_output"}, 200), "reconcile");
});

Deno.test("explicit non-retryable provider 4xx may refund the reservation", () => {
  assertEquals(classifyProviderFailure(providerError(false), 400), "refund");
});

Deno.test("unknown provider outcome fails closed", () => {
  assertEquals(classifyProviderFailure(providerError(false), 503), "reconcile");
});
