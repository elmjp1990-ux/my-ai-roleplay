import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("supabase/functions/chat-turn/index.ts", "utf8");
const summary = readFileSync("supabase/functions/_shared/story-memory-summary.ts", "utf8");
assert.match(source, /const DEFAULT_OPENROUTER_MODEL = "deepseek\/deepseek-v4-flash-0731"/);
assert.doesNotMatch(source, /Deno\.env\.get\("OPENROUTER_MODEL"\)/);
assert.match(source, /provider: \{ only: \["deepinfra"\], allow_fallbacks: false, data_collection: "deny" \}/);
assert.match(source, /processDueStoryMemorySummary\(admin, session, user\.id, openRouterKey\)/);
assert.match(source, /recordChatModelUsage\(admin/);
assert.match(source, /storedSummary/);
assert.match(source, /EdgeRuntime\.waitUntil/);
assert.match(summary, /const SUMMARY_MODEL = "openai\/gpt-oss-20b"/);
assert.match(summary, /const SUMMARY_INTERVAL = 5/);
assert.match(summary, /generation_type: "memory_summary"/);
assert.match(summary, /generation_type: "chat_response"/);
assert.match(summary, /prompt_tokens/);
assert.match(summary, /cost_usd/);
assert.match(summary, /data_collection: "deny"/);
assert.match(summary, /only: \["deepinfra"\]/);

const summaryStart = summary.indexOf("async function requestMemorySummary");
const summaryEnd = summary.indexOf("export async function processDueStoryMemorySummary", summaryStart);
assert.ok(summaryStart >= 0 && summaryEnd > summaryStart, "summary request helper must exist");
const summaryRequest = summary.slice(summaryStart, summaryEnd);
assert.doesNotMatch(summaryRequest, /max_tokens\s*:/, "summary request must not set a client-side token cap");

console.log("Dual-model Story chat and five-turn memory-summary contract passed.");
