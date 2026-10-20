import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { capMemory, replacePromptVariables, taipeiCurrentDate } from "./prompt-variables.ts";

Deno.test("substitutes known variables once and preserves unknown placeholders", () => {
  assertEquals(replacePromptVariables("{USER}|{UNKNOWN}|{CHAR}", { USER: "{CHAR}", CHAR: "Mira" }), "{CHAR}|{UNKNOWN}|Mira");
});

Deno.test("keeps missing known variables empty and trims/caps memory", () => {
  assertEquals(replacePromptVariables("{USER}|{CHAR}", { USER: " 玩家 " }), " 玩家 |");
  assertEquals(capMemory("  紀憶  "), "紀憶");
  assertEquals(capMemory("x".repeat(3500)).length, 3000);
  assertEquals(capMemory("abcdef", 3), "abc");
  assertEquals(capMemory("abcdef", -1), "");
});

Deno.test("uses Asia/Taipei date even near UTC day boundary", () => {
  assertEquals(taipeiCurrentDate(new Date("2026-01-01T17:00:00.000Z")), "2026-01-02");
});
