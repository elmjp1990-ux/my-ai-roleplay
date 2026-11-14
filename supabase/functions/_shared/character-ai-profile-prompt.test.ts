import { assertEquals, assertStringIncludes } from "jsr:@std/assert";
import {
  collectDerivedPrivateProfileValues,
  formatCharacterAiProfilePrompt,
} from "./character-ai-profile-prompt.ts";

Deno.test("formats all character AI profile sections for reuse by chat modes", () => {
  const prompt = formatCharacterAiProfilePrompt({
    identity_background: { items: [{ content: "夜辰是守護者", source_type: "author" }] },
    core_personality: { items: [{ content: "沉著", source_type: "ai_inference" }] },
    speech_style: { tendencies: [{ content: "語氣簡潔" }], creator_defined_quirks: [{ content: "少用驚嘆號" }] },
    ooc_rules: { rules: [{ rule: "不可代替玩家決定", prohibited_deviation: "替玩家行動", allowed_growth: "角色可自主反應" }] },
    author_private_context: { items: [{ content: "只供理解的私密背景" }] },
    unknowns: ["未知的過去"],
    source_conflicts: [{ description: "兩份設定互相矛盾" }],
    status: "insufficient_source",
    insufficient_source_reason: "資料不足",
  });

  assertStringIncludes(prompt, "[身份與背景/作者設定] 夜辰是守護者");
  assertStringIncludes(prompt, "[核心人格與價值觀/AI歸納] 沉著");
  assertStringIncludes(prompt, "[說話風格] 語氣簡潔");
  assertStringIncludes(prompt, "[作者明確提供的固定慣用詞] 少用驚嘆號");
  assertStringIncludes(prompt, "[OOC防崩規則] 不可代替玩家決定");
  assertStringIncludes(prompt, "[作者私密補充/僅供角色理解] 只供理解的私密背景");
  assertStringIncludes(prompt, "[作者未提供/未知] 未知的過去");
  assertStringIncludes(prompt, "[作者設定衝突/不可自行裁決] 兩份設定互相矛盾");
  assertStringIncludes(prompt, "[OOC資料不足] 資料不足");
});

Deno.test("collects only derived values sourced from private character information", () => {
  const values = collectDerivedPrivateProfileValues({
    identity_background: { items: [
      { content: "private phrase", source_refs: ["character_private_info.private_info"] },
      { content: "public phrase", source_refs: ["characters.intro"] },
    ] },
    ooc_rules: { rules: [
      { rule: "private rule", why_it_matters: "private why", prohibited_deviation: "private avoid", allowed_growth: "private growth", source_refs: ["character_private_info.personality_profile"] },
    ] },
  });
  assertEquals(values.includes("private phrase"), true);
  assertEquals(values.includes("public phrase"), false);
  assertEquals(values.includes("private rule"), true);
  assertEquals(values.includes("private why"), true);
});
