import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { detectPlayerSummaryLanguage } from "./story-summary-language.ts";

Deno.test("detects traditional Chinese and forbids simplified conversion", () => {
  assertEquals(
    detectPlayerSummaryLanguage(["今天我想跟你一起去看看，這個地方真的很漂亮。", "我們晚點再說話。"]),
    "繁體中文（使用繁體字，不得轉為簡體中文）",
  );
});

Deno.test("detects simplified Chinese", () => {
  assertEquals(
    detectPlayerSummaryLanguage(["今天我想跟你一起去看看，这个地方真的很漂亮。", "我们晚点再说话。"]),
    "簡體中文（使用簡體字）",
  );
});

Deno.test("detects English, Japanese and Korean inputs", () => {
  assertEquals(detectPlayerSummaryLanguage(["Let's go for coffee and talk about our plans."]), "英文");
  assertEquals(detectPlayerSummaryLanguage(["今日は一緒に行きましょう。"]), "日文");
  assertEquals(detectPlayerSummaryLanguage(["오늘 같이 가요."]), "韓文");
});
