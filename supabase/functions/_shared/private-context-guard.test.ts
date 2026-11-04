import { assertEquals } from "jsr:@std/assert";
import { collectProtectedContext, findPrivateContextLeak } from "./private-context-guard.ts";

Deno.test("collects author-only story notes and personality values without exposing keys", () => {
  const values = collectProtectedContext("隱藏結局：他其實早已知道真相。", {
    coreTraits: "表面冷淡，實際非常重視承諾。",
    likes: ["雨天", "老唱片"],
    enabled: true,
  });
  assertEquals(values.includes("隱藏結局：他其實早已知道真相。"), true);
  assertEquals(values.includes("表面冷淡，實際非常重視承諾。"), true);
  assertEquals(values.includes("雨天"), true);
});

Deno.test("blocks exact private setting disclosure", () => {
  assertEquals(findPrivateContextLeak(
    "其實，他早已知道真相，並且一直隱瞞這件事。",
    ["其實，他早已知道真相，並且一直隱瞞這件事。"],
  ), true);
});

Deno.test("blocks a long copied excerpt even when surrounded by roleplay prose", () => {
  assertEquals(findPrivateContextLeak(
    "他沉默片刻。真正的秘密是那枚戒指早在十年前就被調包，這件事只有作者知道。",
    ["真正的秘密是那枚戒指早在十年前就被調包，這件事只有作者知道。"],
  ), true);
});

Deno.test("normalizes whitespace and punctuation before checking", () => {
  assertEquals(findPrivateContextLeak(
    "真正的秘密，是那枚戒指早在十年前就被調包",
    ["真正的秘密是那枚戒指早在十年前就被調包"],
  ), true);
});

Deno.test("does not block unrelated roleplay output or short common values", () => {
  assertEquals(findPrivateContextLeak(
    "他微微一笑，替你拉開椅子，問你今天過得如何。",
    ["冷淡", "喜歡咖啡"],
  ), false);
});
