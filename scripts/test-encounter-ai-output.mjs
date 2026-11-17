import assert from "node:assert/strict";
import { parseEncounterTurnOutput } from "../supabase/functions/_shared/encounter-turn-output.mjs";

const text = "這是一段相遇模式回覆。".repeat(15);
assert.equal(Array.from(text).length, 150);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: text })), text);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: "太短了" })), null);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: "相遇內容".repeat(38) })), null);
assert.equal(parseEncounterTurnOutput("not-json"), null);
assert.equal(parseEncounterTurnOutput(JSON.stringify(["not", "an", "object"])), null);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: 123 })), null);

const max = "相遇內容".repeat(75);
assert.equal(Array.from(max).length, 300);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: max })), max);

console.log("Encounter AI output contract tests passed.");
