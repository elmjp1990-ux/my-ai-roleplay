import assert from "node:assert/strict";
import fs from "node:fs";

const chatTurn = fs.readFileSync("supabase/functions/chat-turn/index.ts", "utf8");
const modeMigration = fs.readFileSync(
  "supabase/migrations/20261028170000_trusted_chat_mode_marker.sql",
  "utf8",
);
const guardMigration = fs.readFileSync(
  "supabase/migrations/20261028173000_enforce_trusted_chat_mode.sql",
  "utf8",
);

// The generic story billing handler must load the persisted mode and fail closed.
assert.match(chatTurn, /select\(["']id,user_id,deleted_at,character_id,character_snapshot,chat_mode["']\)/);
assert.match(chatTurn, /session\.chat_mode\s*===\s*["']encounter["']/);
assert.match(chatTurn, /encounter_turn_handler_required/);
assert.match(chatTurn, /session\.chat_mode\s*!==\s*["']story["']/);

// Existing sessions must default to Story Mode; the DB constraint limits valid modes.
assert.match(modeMigration, /ADD COLUMN IF NOT EXISTS chat_mode text NOT NULL DEFAULT ['"]story['"]/);
assert.match(modeMigration, /CHECK \(chat_mode IN \(['"]story['"], ['"]encounter['"]\)\)/);

// The DB trigger is required because column-level REVOKE cannot override table-level grants.
assert.match(guardMigration, /SECURITY DEFINER/);
assert.match(guardMigration, /SET search_path = ['"]{2}/);
assert.match(guardMigration, /COALESCE\(auth\.role\(\), ['"]['"]\) <> ['"]service_role['"]/);
assert.match(guardMigration, /NEW\.chat_mode := ['"]story['"]/);
assert.match(guardMigration, /NEW\.chat_mode IS DISTINCT FROM OLD\.chat_mode/);
assert.match(guardMigration, /BEFORE INSERT OR UPDATE OF chat_mode ON public\.chat_sessions/);
assert.match(guardMigration, /REVOKE ALL ON FUNCTION public\.enforce_trusted_chat_mode\(\) FROM PUBLIC, anon, authenticated/);

console.log("Encounter chat-mode security guard tests passed.");
