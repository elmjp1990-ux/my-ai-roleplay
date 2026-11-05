import { assertEquals } from "jsr:@std/assert";
import { buildPromptVariableValues, applyPromptVariables } from "./prompt-context.ts";

Deno.test("builds player persona from session override, not profile bio", () => {
  const values = buildPromptVariableValues({
    profile: { nickname: "N", bio: "public profile bio", persona_presets: [{ name: "default", text: "default roleplay persona", isDefault: true }] },
    sessionData: { persona: "this chat persona" },
    character: { id: "c1", name: "Mira", intro: "A florist" },
    messages: [{ id: "u1", role: "user", content: "hello" }],
    now: new Date("2026-01-01T17:00:00.000Z"),
  });
  assertEquals(values.USER_DESC, "this chat persona");
  assertEquals(values.CHAR_DESC, "A florist");
  assertEquals(values.USER_MESSAGE, "hello");
  assertEquals(values.CURRENT_DATE, "2026-01-02");
});

Deno.test("counts a group turn once even when multiple speakers share it", () => {
  const values = buildPromptVariableValues({
    character: { id: "a", name: "A" },
    group: { name: "G", world_background: "W", members: [
      { character_id: "a", character_snapshot: { id: "a", name: "A" } },
      { character_id: "b", character_snapshot: { id: "b", name: "B" } },
    ] },
    messages: [
      { id: "u1", speaker_type: "player", turn_id: "t1", content: "hi" },
      { id: "a1", speaker_type: "character", turn_id: "t1", content: "hello", speaker_snapshot: { name: "A" } },
      { id: "b1", speaker_type: "character", turn_id: "t1", content: "hey", speaker_snapshot: { name: "B" } },
      { id: "u2", speaker_type: "player", turn_id: "t2", content: "next" },
    ],
  });
  assertEquals(values.TURN_COUNT, "2");
  assertEquals(values.CHAR_LIST, "A、B");
  assertEquals(values.OTHER_CHARS, "B");
  assertEquals(values.GROUP_WORLD, "W");
  const groupPlayer = buildPromptVariableValues({ profile: { nickname: "Account nickname" }, group: { player_name: "Story name", player_persona: "Group persona" } });
  assertEquals(groupPlayer.USER, "Story name");
  assertEquals(groupPlayer.USER_DESC, "Group persona");
});

Deno.test("substitutes known tokens once and preserves unknown tokens", () => {
  const values = buildPromptVariableValues({ character: { name: "Mira" } });
  assertEquals(applyPromptVariables("{CHAR}|{UNKNOWN}|{USER}", { ...values, USER: "{CHAR}" }), "Mira|{UNKNOWN}|{CHAR}");
});

Deno.test("caps memory at 3000 characters and excludes current message from history", () => {
  const values = buildPromptVariableValues({
    sessionData: { memories: [{ summary: "x".repeat(3500) }] },
    messages: [
      { id: "u1", role: "user", content: "old question" },
      { id: "a1", role: "assistant", content: "old answer" },
      { id: "u2", role: "user", content: "current question" },
    ],
    currentUserMessageId: "u2",
  });
  assertEquals(values.MEMORY.length, 3000);
  assertEquals(values.USER_MESSAGE, "current question");
  assertEquals(values.CHAT_HISTORY.includes("current question"), false);
  assertEquals(values.CHAT_HISTORY.includes("old answer"), true);
});

Deno.test("formats structured creator personality without exposing private info", () => {
  const values = buildPromptVariableValues({
    character: {
      name: "Mira",
      style: "Warm, descriptive prose",
      intro: "A florist",
      personality_profile: {
        coreTraits: "Observant and guarded",
        values: "Keeps promises",
        speechStyle: "Short sentences",
        behaviorRules: "Pauses when upset",
        likes: "Rainy afternoons",
        dislikes: "Broken promises",
        boundaries: "Respect personal space",
        relationshipPacing: "Slow burn",
        private_info: "THIS MUST NOT APPEAR",
      },
    },
  });
  assertEquals(values.CHAR_STYLE, "Warm, descriptive prose");
  assertEquals(values.CHAR_PERSONALITY.includes("核心性格：Observant and guarded"), true);
  assertEquals(values.CHAR_PERSONALITY.includes("關係發展節奏：Slow burn"), true);
  assertEquals(values.CHAR_PERSONALITY.includes("喜好："), false);
  assertEquals(values.CHAR_LIKES, "喜歡：Rainy afternoons");
  assertEquals(values.CHAR_DISLIKES, "不喜歡／雷點：Broken promises");
  assertEquals(values.CHAR_PERSONALITY.includes("THIS MUST NOT APPEAR"), false);
  assertEquals(values.CHAR_PERSONALITY.length <= 4000, true);
});

Deno.test("empty or malformed character personality safely falls back to empty context", () => {
  const empty = buildPromptVariableValues({ character: { personality_profile: null } });
  const malformed = buildPromptVariableValues({ character: { personality_profile: ["not", "an", "object"] } });
  assertEquals(empty.CHAR_PERSONALITY, "");
  assertEquals(empty.CHAR_LIKES, "");
  assertEquals(empty.CHAR_DISLIKES, "");
  assertEquals(malformed.CHAR_PERSONALITY, "");
});

Deno.test("important memories and recent entries are retained before older ordinary entries", () => {
  const values = buildPromptVariableValues({
    sessionData: { memories: [
      { text: "OLD_ENTRY_".repeat(500), important: false, at: 1 },
      { text: "PINNED_MEMORY", important: true, at: 2 },
      { text: "RECENT_MEMORY", important: false, at: 3 },
    ] },
  });
  assertEquals(values.MEMORY.includes("PINNED_MEMORY"), true);
  assertEquals(values.MEMORY.includes("RECENT_MEMORY"), true);
  assertEquals(values.MEMORY.length <= 3000, true);
  assertEquals(values.MEMORY.indexOf("重大記憶") < values.MEMORY.indexOf("回憶摘錄"), true);
});


Deno.test("keeps an explicit current player correction alongside older memory for prompt priority rules", () => {
  const values = buildPromptVariableValues({
    sessionData: { memories: [{ text: "舊記憶：玩家住在台北", important: true, at: 1 }] },
    messages: [{ id: "u-correction", role: "user", content: "更正：我已搬到台中，之後請以台中為準。" }],
    currentUserMessageId: "u-correction",
  });
  assertEquals(values.MEMORY.includes("玩家住在台北"), true);
  assertEquals(values.USER_MESSAGE, "更正：我已搬到台中，之後請以台中為準。");
  assertEquals(values.CHAT_HISTORY.includes("更正：我已搬到台中"), false);
});
