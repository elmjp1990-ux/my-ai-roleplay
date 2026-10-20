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