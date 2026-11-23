import { assertEquals } from "jsr:@std/assert";
import {
  APPROVED_OPENROUTER_PROVIDERS,
  buildOpenRouterProviderOptions,
} from "./openrouter-provider-policy.ts";

Deno.test("OpenRouter only routes to the approved non-training provider allowlist", () => {
  assertEquals(APPROVED_OPENROUTER_PROVIDERS, ["deepinfra", "inference-net"]);
  assertEquals(buildOpenRouterProviderOptions("deepinfra"), {
    only: ["deepinfra"],
    allow_fallbacks: false,
    data_collection: "allow",
  });
  assertEquals(buildOpenRouterProviderOptions("inference-net"), {
    only: ["inference-net"],
    allow_fallbacks: false,
    data_collection: "allow",
  });
});

Deno.test("OpenRouter routing fails closed instead of using an unapproved fallback", () => {
  const policy = buildOpenRouterProviderOptions();
  assertEquals(policy.only, ["deepinfra"]);
  assertEquals(policy.allow_fallbacks, false);
  assertEquals(policy.data_collection, "allow");
});
