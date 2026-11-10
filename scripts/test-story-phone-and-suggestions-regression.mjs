import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const html = readFileSync("index.html", "utf8");
const edge = readFileSync("supabase/functions/chat-turn/index.ts", "utf8");
const phoneMigration = readFileSync("supabase/migrations/20261110120000_story_phone_state_and_memory_summary_read.sql", "utf8");
const worldMigration = readFileSync("supabase/migrations/20261110235500_story_world_state_contextual_time_location.sql", "utf8");
const suggestionMigration = readFileSync("supabase/migrations/20261111100000_story_suggested_replies_persistence.sql", "utf8");
const eightFieldMigration = readFileSync("supabase/migrations/20261106140000_expand_story_phone_events_to_five_fields.sql", "utf8");
const affinityMigration = readFileSync("supabase/migrations/20261106090000_story_turn_affinity_and_phone_events.sql", "utf8");
const memoryImportanceMigration = readFileSync("supabase/migrations/20261110205546_story_memory_summary_important_toggle.sql", "utf8");

assert.match(html, /const \[eventsResult,stateResult,worldStateResult\]=await Promise\.all\(/);
assert.match(html, /get_story_world_state/);
assert.match(html, /select\('id,session_id,role,content,created_at,suggested_replies'\)/);
assert.match(html, /message\.suggested_replies/);
assert.match(html, /result\.suggestedReplies\).*result\.suggested_replies/s);

// Author-configured phone fields and genuine event history render inside one list,
// with the configured fields first and no more than eight combined rows.
assert.match(html, /storyPhoneStates\.slice\(0,8\)/);
assert.match(html, /storyPhoneEvents\.slice\(0,Math\.max\(0,8-storyPhoneStates\.length\)\)/);
assert.match(html, /const noticeContentHTML=\[\s*storyStateHTML,\s*storyEventHTML/s);

// Per-message persisted suggestions override stale session metadata on reload.
assert.match(html, /Object\.assign\(normalized,metadata\);[\s\S]{0,260}if\(persistedSuggestions\.length===3\)normalized\.suggestedReplies=persistedSuggestions/);

// Refresh the owner-checked relationship RPC after every successful Story turn.
assert.match(html, /if\(s\.storyMode\) await loadStoryRelationshipState\(s\)/);
assert.match(html, /get_story_relationship_state/);

// World state is generated in the same Story call, persisted after settlement,
// and read back through an owner-scoped RPC.
assert.match(edge, /story_world_states"\)\.upsert/);
assert.match(edge, /apply_story_turn_evaluation/);
assert.match(worldMigration, /get_story_world_state/);
assert.match(worldMigration, /Story owners can read their world state/);

// Affinity is queued from the model's per-turn result and applied only after settlement.
assert.match(edge, /p_affinity_delta: turnEnvelope\.affinity_delta/);
assert.match(edge, /affinity_delta 必須是 -3 到 3 的整數，而且每回合都要重新評估/);
assert.match(affinityMigration, /v_affinity := GREATEST\(-100, LEAST\(100, v_state\.affinity \+ v_eval\.affinity_delta\)\)/);
assert.match(phoneMigration, /turn_count_since_summary = mod\(turn_count_since_summary \+ 1, 5\)/);

// The eight author-defined phone fields fit both the DB event index and payload limits.
assert.match(eightFieldMigration, /jsonb_array_length\(COALESCE\(p_phone_events,/);
assert.match(eightFieldMigration, /event_index BETWEEN 0 AND 7/);

// Exactly three suggestions are persisted on the assistant message and restored on reload.
assert.match(edge, /suggested_replies: turnEnvelope\.suggested_replies/);
// Legacy raw quote memories are excluded from Story prompts; only AI summaries
// explicitly marked important are promoted into the long-term MEMORY slot.
assert.match(edge, /\.eq\("important", true\)/);
assert.match(edge, /sessionData\.memories = importantSummaryRows\.map/);
assert.match(edge, /sessionData\.memory = \[\]/);
assert.match(edge, /never feed legacy player\/character quote cards/);
assert.match(edge, /select\("id,content,suggested_replies"\)/);
assert.match(suggestionMigration, /ADD COLUMN IF NOT EXISTS suggested_replies jsonb/);
assert.match(suggestionMigration, /jsonb_array_length\(suggested_replies\) <= 3/);

// Story long-term memory shows only AI-generated summaries, with timestamps
// and a persisted, owner-checked important-memory toggle; raw quote cards stay hidden.
assert.match(html, /get_story_memory_summaries/);
assert.match(html, /data-story-memory-batch/);
assert.match(html, /set_story_memory_summary_important/);
assert.match(html, /s\.storyMode \? '' : \(\(s\.memories\|\|\[\]\)\.map/);
assert.doesNotMatch(html, /系統會保存玩家原話與相關角色回應/);
assert.match(memoryImportanceMigration, /ADD COLUMN IF NOT EXISTS important boolean NOT NULL DEFAULT false/);
assert.match(memoryImportanceMigration, /s\.user_id = \(SELECT auth\.uid\(\)\)/);
assert.match(memoryImportanceMigration, /s\.chat_mode = 'story'/);
assert.match(memoryImportanceMigration, /GRANT EXECUTE ON FUNCTION public\.set_story_memory_summary_important/);
console.log("Story phone, world-state, affinity, suggestions, and AI-summary-only memory checks passed.");
