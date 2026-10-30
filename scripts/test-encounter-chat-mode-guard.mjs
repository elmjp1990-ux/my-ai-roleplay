import assert from "node:assert/strict";
import fs from "node:fs";

const chatTurn = fs.readFileSync("supabase/functions/chat-turn/index.ts", "utf8");
const modeMigration = fs.readFileSync("supabase/migrations/20261028170000_trusted_chat_mode_marker.sql", "utf8");
const guardMigration = fs.readFileSync("supabase/migrations/20261028173000_enforce_trusted_chat_mode.sql", "utf8");

assert.match(chatTurn, /select\(["']id,user_id,deleted_at,character_id,character_snapshot,chat_mode["']\)/);
assert.match(chatTurn, /session\.chat_mode\s*===\s*["']encounter["']/);
assert.match(chatTurn, /encounter_turn_handler_required/);
assert.match(chatTurn, /session\.chat_mode\s*!==\s*["']story["']/);
assert.match(modeMigration, /ADD COLUMN IF NOT EXISTS chat_mode text NOT NULL DEFAULT ['"]story['"]/);
assert.match(modeMigration, /CHECK \(chat_mode IN \(['"]story['"], ['"]encounter['"]\)\)/);
assert.match(guardMigration, /SECURITY DEFINER/);
assert.match(guardMigration, /SET search_path = ['"]{2}/);
assert.match(guardMigration, /NEW\.chat_mode IS DISTINCT FROM OLD\.chat_mode/);

const encounterSession = fs.readFileSync("supabase/functions/encounter-session/index.ts", "utf8");
const accessMigration = fs.readFileSync("supabase/migrations/20261028180000_encounter_session_access_check.sql", "utf8");
assert.match(encounterSession, /auth\.getUser\(\)/);
assert.match(encounterSession, /rpc\(["']account_is_active["']\)/);
assert.match(encounterSession, /can_open_encounter_session/);
assert.match(encounterSession, /session_id_conflict/);
assert.match(accessMigration, /private\.current_user_is_adult\(\)/);
assert.doesNotMatch(encounterSession, /\.eq\(["']latest_eligible["'],\s*true\)/);

const encounterTurn = fs.readFileSync("supabase/functions/encounter-turn/index.ts", "utf8");
assert.match(encounterTurn, /auth\.getUser\(\)/);
assert.match(encounterTurn, /session\.chat_mode !== ["']encounter["']/);
assert.match(encounterTurn, /reserve_chat_turn/);
assert.match(encounterTurn, /settle_chat_turn/);
assert.match(encounterTurn, /record_encounter_turn_interaction/);
assert.match(encounterTurn, /assistant_message_id_collision/);

const interactionMigration = fs.readFileSync(
  "supabase/migrations/20261029210000_validate_settled_encounter_interaction.sql",
  "utf8",
);
assert.match(interactionMigration, /v_charge\.status IS DISTINCT FROM ['"]settled['"]/);
assert.match(interactionMigration, /v_charge\.assistant_message_id IS DISTINCT FROM v_charge\.expected_assistant_message_id/);
assert.match(interactionMigration, /p_metadata ->> ['"]session_id['"]/);
assert.match(interactionMigration, /p_metadata ->> ['"]user_message_id['"]/);
assert.match(interactionMigration, /p_metadata ->> ['"]assistant_message_id['"]/);
assert.match(interactionMigration, /s\.chat_mode = ['"]encounter['"]/);
assert.match(interactionMigration, /m\.role = ['"]user['"]/);
assert.match(interactionMigration, /m\.role = ['"]assistant['"]/);
assert.match(interactionMigration, /REVOKE ALL ON FUNCTION public\.record_encounter_turn_interaction/);
assert.match(interactionMigration, /GRANT EXECUTE ON FUNCTION public\.record_encounter_turn_interaction[^;]*TO service_role/s);

const frontend = fs.readFileSync("index.html", "utf8");
assert.match(frontend, /async function createEncounterSession\(character\)/);
assert.match(frontend, /functions\.invoke\(["']encounter-session["']/);
assert.match(frontend, /const endpointName = s\.encounterMode \? ["']encounter-turn["'] : ["']chat-turn["']/);
console.log("Encounter chat-mode security guard tests passed.");
