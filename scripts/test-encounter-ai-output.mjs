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
const frontend = fs.readFileSync("index.html", "utf8");
const scene = fs.readFileSync("encounter-scene.js", "utf8");
assert.match(endpoint, /requestOpenRouterChatCompletion/);
assert.match(endpoint, /POYOZZ_DEFAULT_CHAT_MODEL/);
assert.match(endpoint, /reserve_encounter_chat_turn/);
assert.match(endpoint, /releaseGenerationClaim/);
assert.match(endpoint, /refundEncounterTurn/);
assert.equal((endpoint.match(/admin\.rpc\(["\']refund_chat_turn["\']/g) || []).length, 1, "Refund logic must be centralized");
assert.match(endpoint, /findPrivateContextLeak/);
assert.match(endpoint, /record_encounter_session_turn_evidence/);
assert.match(endpoint, /settle_chat_turn/);
assert.doesNotMatch(endpoint, /demoReply/);
assert.ok(
  endpoint.indexOf('if (!openRouterKey)') < endpoint.indexOf('reserve_encounter_chat_turn'),
  "Missing OpenRouter credentials must fail before wallet reservation",
);
assert.match(endpoint, /provider_generation_outcome_unknown/);
assert.match(endpoint, /provider_request_refund/);
assert.doesNotMatch(endpoint, /classifyProviderFailure/);
assert.match(endpoint, /generation_already_claimed/);
assert.match(guidelines, /150～300 字元/);
assert.match(guidelines, /buildRoleplayResponseGuidelines\(["']single["']\)/);
assert.match(frontend, /poyozz-encounter-opening-choice/);
assert.match(frontend, /initialOpeningMessage = \{ text: greeting, at: Date\.now\(\) \}/);
assert.match(scene, /data-action="encounter-opening-choice"/);
assert.match(scene, /data-choice="greet"/);
assert.match(scene, /data-choice="wait"/);
assert.match(endpoint, /openingMessage = asRow\(asRow\(session\.session_data\)\.openingMessage\)/);
const openingHandlerStart = frontend.indexOf("window.addEventListener('poyozz-encounter-opening-choice'");
const openingHandlerEnd = frontend.indexOf("async function markCloudChatSessionRead", openingHandlerStart);
assert.ok(openingHandlerStart >= 0 && openingHandlerEnd > openingHandlerStart, "Opening-choice persistence handler must exist");
const openingHandler = frontend.slice(openingHandlerStart, openingHandlerEnd);
assert.doesNotMatch(openingHandler, /executePendingChatTurn|reserve_encounter_chat_turn/,
  "Free opening choice must not call AI or reserve wallet funds");

console.log("Encounter AI output, billing safety, and opening-choice contract tests passed.");
