import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("supabase/functions/chat-turn/index.ts", "utf8");
assert.match(source, /const DEFAULT_OPENROUTER_MODEL = "deepseek\/deepseek-v4-flash-0731"/);
assert.match(source, /const MEMORY_SUMMARY_MODEL = "openai\/gpt-oss-20b"/);
assert.doesNotMatch(source, /Deno\.env\.get\("OPENROUTER_MODEL"\)/);
assert.match(source, /provider: \{ only: \["deepinfra"\], allow_fallbacks: false, data_collection: "deny" \}/);
assert.match(source, /const MEMORY_SUMMARY_INTERVAL = 5/);
assert.match(source, /generation_type: "memory_summary"/);
assert.match(source, /generation_type: "chat_response"/);
assert.match(source, /EdgeRuntime\.waitUntil/);
assert.match(source, /ai_model_usage/);
assert.match(source, /storedSummary/);
assert.match(source, /prompt_tokens/);
assert.match(source, /cost_usd/);

const summaryStart = source.indexOf("async function requestMemorySummary");
const summaryEnd = source.indexOf("async function processDueStoryMemorySummary", summaryStart);
assert.ok(summaryStart >= 0 && summaryEnd > summaryStart, "summary request helper must exist");
const summaryRequest = source.slice(summaryStart, summaryEnd);
assert.doesNotMatch(summaryRequest, /max_tokens\s*:/, "memory summary request must not set a client-side token cap");

console.log("Dual-model Story chat and five-turn memory-summary contract passed.");
