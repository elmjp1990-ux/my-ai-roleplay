import { assertEquals } from "jsr:@std/assert";
import { collectProtectedContext, findPrivateContextLeak, preparePrivateContext } from "./private-context-guard.ts";

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

Deno.test("caps prompt text but screens the complete private source", () => {
  const secretTail = "只有作者知道的最終秘密是主角其實早已收到那封信而且他決定永遠不說出來。";
  const privateInfo = "前段公開背景。" + "一般劇情描述。".repeat(1001) + secretTail;
  const prepared = preparePrivateContext(privateInfo, { coreTraits: "冷靜而謹慎" }, 6000);
  assertEquals(prepared.promptText.length, 6000);
  assertEquals(prepared.protectedValues.includes(privateInfo), true);
  assertEquals(findPrivateContextLeak(
    "他說出了秘密：" + secretTail.slice(0, 32),
    prepared.protectedValues,
  ), true);
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

Deno.test("blocks a long partial excerpt but ignores short shared phrases", () => {
  const privateSetting = "作者設定中真正不可公開的核心秘密是十年前那場事故其實由家族內部策劃，而且所有證據都被刻意隱藏，這是故事後期才會揭露的真相。";
  assertEquals(findPrivateContextLeak(
    "他低聲說道：" + privateSetting.slice(12, 48),
    [privateSetting],
  ), true);
  assertEquals(findPrivateContextLeak(
    "他喜歡安靜地喝咖啡，偶爾也會看看窗外的雨。",
    ["角色平常喜歡安靜地喝咖啡，偶爾也會看看窗外的雨，並且習慣在雨天獨自散步。"],
  ), false);
});

Deno.test("normalizes whitespace and punctuation before checking", () => {
  assertEquals(findPrivateContextLeak(
    "真正的秘密，是那枚戒指早在十年前就被調包",
    ["真正的秘密是那枚戒指早在十年前就被調包"],
  ), true);
});

Deno.test("blocks URL-encoded and Base64 copies of long private settings", () => {
  const secret = "作者私密設定中真正不能公開的劇情真相是十年前那場事故由家族內部策劃，所有證據都被刻意隱藏。";
  const bytes = new TextEncoder().encode(secret);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const base64 = btoa(binary);

  assertEquals(findPrivateContextLeak("這是編碼內容：" + base64, [secret]), true);
  assertEquals(findPrivateContextLeak("這是網址編碼：" + encodeURIComponent(secret), [secret]), true);
});

Deno.test("does not block unrelated roleplay output or short common values", () => {
  assertEquals(findPrivateContextLeak(
    "他微微一笑，替你拉開椅子，問你今天過得如何。",
    ["冷淡", "喜歡咖啡"],
  ), false);
});


Deno.test("blocks a private setting stitched across recent assistant turns", () => {
  const secret = "作者私密劇情的真正關鍵是那場十年前的事故由家族內部策劃，所有證據都被刻意隱藏，直到故事後期才會揭露。";
  const fragments = [
    secret.slice(0, 20),
    secret.slice(20, 40),
    secret.slice(40, 60),
  ];
  for (const fragment of fragments) {
    assertEquals(findPrivateContextLeak(fragment, [secret]), false);
  }
  assertEquals(findPrivateContextLeak(fragments[2], [secret], fragments.slice(0, 2)), true);
});
