import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("supabase/functions/chat-turn/index.ts", "utf8");
const openRouterShared = readFileSync("supabase/functions/_shared/openrouter-chat-completions.ts", "utf8");
const summary = readFileSync("supabase/functions/_shared/story-memory-summary.ts", "utf8");
const migration = readFileSync("supabase/migrations/20261105223613_ai_model_usage_and_memory_summaries.sql", "utf8");
const summaryReadMigration = readFileSync("supabase/migrations/20261110120000_story_phone_state_and_memory_summary_read.sql", "utf8");
const ui = readFileSync("index.html", "utf8");
assert.match(source, /const DEFAULT_OPENROUTER_MODEL = POYOZZ_DEFAULT_CHAT_MODEL/);
assert.match(openRouterShared, /POYOZZ_DEFAULT_CHAT_MODEL = "deepseek\/deepseek-v4-flash-20260423"/);
assert.doesNotMatch(source, /Deno\.env\.get\("OPENROUTER_MODEL"\)/);
assert.match(openRouterShared, /provider: \{ only: \["deepinfra"\], allow_fallbacks: false, data_collection: "deny" \}/);
assert.match(source, /processDueStoryMemorySummary\(admin, session, user\.id, openRouterKey\)/);
assert.match(source, /recordChatModelUsage\(admin/);
assert.match(source, /storedSummary/);
assert.match(source, /edgeRuntime\?\.waitUntil/);
assert.match(summary, /const SUMMARY_MODEL = "openai\/gpt-oss-20b"/);
assert.match(summary, /const SUMMARY_INTERVAL = 5/);
assert.match(summary, /generation_type: "memory_summary"/);
assert.match(summary, /generation_type: "chat_response"/);
assert.match(summary, /prompt_tokens/);
assert.match(summary, /cost_usd/);
assert.match(summary, /accumulatedUsage/);
assert.match(summary, /data_collection: "deny"/);
assert.match(summaryReadMigration, /CREATE OR REPLACE FUNCTION public\.get_story_memory_summary/);
assert.match(summaryReadMigration, /auth\.uid\(\)/);
assert.match(ui, /function loadStoryMemorySummary\(session\)/);
assert.match(ui, /get_story_memory_summaries/);
assert.match(ui, /data-action="edit-story-memory"/);
assert.match(ui, /data-form="story-memory-edit"/);
assert.match(ui, /update_story_memory_summary/);
assert.doesNotMatch(ui, /AI 劇情回憶摘要 · 第 /);
assert.doesNotMatch(ui, /SWEET DIARY · LONG-TERM MEMORY/);
assert.match(ui, /設為重大記憶/);
assert.match(summaryReadMigration, /latest_completed/);

// Usage rows with a persisted assistant reply must be written only after that
// message exists; failed or blocked generations intentionally store a null FK.
const assistantInsert = source.indexOf('admin.from("chat_messages").insert(assistantRow)');
const successfulUsageWrite = source.indexOf('await recordUsage(assistantMessageId, "completed")');
assert.ok(assistantInsert >= 0 && successfulUsageWrite > assistantInsert,
  "successful model usage must be recorded after assistant-message persistence");
assert.match(source, /await recordUsage\(null, "failed"\)/,
  "failed or blocked provider generations must still be recorded without an assistant FK");
assert.match(migration, /turn_id uuid references public\.chat_turn_charges\(turn_id\) on delete cascade/);
assert.doesNotMatch(migration, /generation_type = 'chat_response' and turn_id is not null and assistant_message_id is not null/,
  "chat usage rows must allow null assistant IDs for failed or blocked generations");
assert.match(summary, /only: \["deepinfra"\]/);

const summaryStart = summary.indexOf("async function requestMemorySummary");
const summaryEnd = summary.indexOf("export async function processDueStoryMemorySummary", summaryStart);
assert.ok(summaryStart >= 0 && summaryEnd > summaryStart, "summary request helper must exist");
const summaryRequest = summary.slice(summaryStart, summaryEnd);
assert.doesNotMatch(summaryRequest, /max_tokens\s*:/, "summary request must not set a client-side token cap");

console.log("Dual-model Story chat and five-turn memory-summary contract passed.");
