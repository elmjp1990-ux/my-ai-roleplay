import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildPromptVariableValues, replacePromptVariables } from "./prompt-variables.ts";

Deno.test("counts player turns once per turn_id across group speakers", () => {
  const values = buildPromptVariableValues({
    character: { id: "a", name: "A" },
    activeCharacter: { id: "a", name: "A" },
    group: { name: "group", members: [
      { character_id: "a", character_snapshot: { id: "a", name: "A" } },
      { character_id: "b", character_snapshot: { id: "b", name: "B" } },
    ] },
    messages: [
      { id: "u1", speaker_type: "player", turn_id: "t1", content: "hi" },
      { id: "a1", speaker_type: "character", turn_id: "t1", content: "hello", speaker_snapshot: { name: "A" } },
      { id: "b1", speaker_type: "character", turn_id: "t1", content: "hey", speaker_snapshot: { name: "B" } },
      { id: "u2", role: "user", turn_id: "t2", content: "next" },
    ],
  });
  assertEquals(values.TURN_COUNT, "2");
  assertEquals(values.CHAR_LIST, "A、B");
  assertEquals(values.OTHER_CHARS, "B");
});

Deno.test("substitutes known variables once and preserves unknown placeholders", () => {
  assertEquals(
    replacePromptVariables("{USER}|{UNKNOWN}|{CHAR}", { USER: "{CHAR}", CHAR: "Mira" }),
    "{CHAR}|{UNKNOWN}|Mira",
  );
});

Deno.test("keeps empty known values empty and caps memory", () => {
  const values = buildPromptVariableValues({
    user: { nickname: "玩家" },
    character: { name: "角色" },
    session: { memories: [{ summary: "x".repeat(3500) }] },
    messages: [{ id: "u", role: "user", content: "當前訊息" }],
  });
  assertEquals(values.USER_GENDER, "");
  assertEquals(values.MEMORY.length, 3000);
  assertEquals(values.USER_MESSAGE, "當前訊息");
});

Deno.test("uses Asia/Taipei date even near UTC day boundary", () => {
  const values = buildPromptVariableValues({
    now: new Date("2026-01-01T17:00:00.000Z"),
  });
  assertEquals(values.CURRENT_DATE, "2026-01-02");
});
