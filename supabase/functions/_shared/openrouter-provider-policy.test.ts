import { assertEquals } from "jsr:@std/assert";
import {
  APPROVED_OPENROUTER_PROVIDERS,
  buildOpenRouterProviderOptions,
} from "./openrouter-provider-policy.ts";

Deno.test("OpenRouter only routes to the approved non-training provider allowlist", () => {
  assertEquals(APPROVED_OPENROUTER_PROVIDERS, ["deepinfra", "inference-net"]);
  assertEquals(buildOpenRouterProviderOptions(), {
    only: ["deepinfra", "inference-net"],
    allow_fallbacks: false,
    data_collection: "deny",
  });
});

Deno.test("OpenRouter routing fails closed instead of using an unapproved fallback", () => {
  const policy = buildOpenRouterProviderOptions();
  assertEquals(policy.allow_fallbacks, false);
  assertEquals(policy.data_collection, "deny");
  assertEquals(policy.only.includes("deepseek" as never), false);
});
