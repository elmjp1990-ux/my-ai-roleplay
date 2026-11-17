import assert from "node:assert/strict";
import fs from "node:fs";
import { parseEncounterTurnOutput } from "../supabase/functions/_shared/encounter-turn-output.mjs";

const text = "相遇內容。".repeat(30);
assert.equal(Array.from(text).length, 150);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: text })), text);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: "太短了" })), null);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: "相遇內容".repeat(76) })), null);
assert.equal(parseEncounterTurnOutput("not-json"), null);
assert.equal(parseEncounterTurnOutput(JSON.stringify(["not", "an", "object"])), null);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: 123 })), null);

const max = "相遇內容".repeat(75);
assert.equal(Array.from(max).length, 300);
assert.equal(parseEncounterTurnOutput(JSON.stringify({ reply: max })), max);

const endpoint = fs.readFileSync("supabase/functions/encounter-turn/index.ts", "utf8");
const guidelines = fs.readFileSync("supabase/functions/_shared/encounter-response-guidelines.ts", "utf8");
assert.match(endpoint, /requestOpenRouterChatCompletion/);
assert.match(endpoint, /POYOZZ_DEFAULT_CHAT_MODEL/);
assert.match(endpoint, /reserve_encounter_chat_turn/);
assert.match(endpoint, /releaseGenerationClaim/);
assert.match(endpoint, /refund_chat_turn/);
assert.match(endpoint, /findPrivateContextLeak/);
assert.match(endpoint, /record_encounter_session_turn_evidence/);
assert.match(endpoint, /settle_chat_turn/);
assert.doesNotMatch(endpoint, /demoReply/);
assert.ok(
  endpoint.indexOf('if (!openRouterKey)') < endpoint.indexOf('reserve_encounter_chat_turn'),
  "Missing OpenRouter credentials must fail before wallet reservation",
);
assert.match(endpoint, /provider_generation_outcome_unknown/);
assert.match(endpoint, /generation_already_claimed/);
assert.match(guidelines, /150～300 字元/);
assert.match(guidelines, /buildRoleplayResponseGuidelines\(["']single["']\)/);

console.log("Encounter AI output, billing safety, and integration contract tests passed.");
