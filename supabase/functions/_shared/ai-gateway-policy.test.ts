import { assertEquals } from "jsr:@std/assert";
import { buildGatewayProviderOptions } from "./ai-gateway-policy.ts";

Deno.test("Chat Completions requests require Vercel no-prompt-training routing", () => {
  assertEquals(buildGatewayProviderOptions(), {
    gateway: { disallowPromptTraining: true },
  });
});
