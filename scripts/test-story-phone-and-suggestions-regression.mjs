import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const html = readFileSync("index.html", "utf8");
const edge = readFileSync("supabase/functions/chat-turn/index.ts", "utf8");
const migration = readFileSync("supabase/migrations/20261111100000_story_suggested_replies_persistence.sql", "utf8");

assert.match(html, /const \[eventsResult,stateResult,worldStateResult\]=await Promise\.all\(/);
assert.match(html, /get_story_world_state/);
assert.match(html, /select\('id,session_id,role,content,created_at,suggested_replies'\)/);
assert.match(html, /message\.suggested_replies/);
assert.match(html, /result\.suggestedReplies\).*result\.suggested_replies/s);
assert.match(edge, /suggested_replies: turnEnvelope\.suggested_replies/);
assert.match(edge, /select\("id,content,suggested_replies"\)/);
assert.match(migration, /ADD COLUMN IF NOT EXISTS suggested_replies jsonb/);
assert.match(migration, /jsonb_array_length\(suggested_replies\) <= 3/);
console.log("Story phone RPC destructuring and per-message suggested reply persistence checks passed.");
