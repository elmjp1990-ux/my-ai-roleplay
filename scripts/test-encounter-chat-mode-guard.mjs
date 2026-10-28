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


const encounterSession = fs.readFileSync(
  "supabase/functions/encounter-session/index.ts",
  "utf8",
);
const accessMigration = fs.readFileSync(
  "supabase/migrations/20261028180000_encounter_session_access_check.sql",
  "utf8",
);

// Session creation must authenticate the caller and derive identity from the JWT.
assert.match(encounterSession, /auth\.getUser\(\)/);
assert.match(encounterSession, /rpc\(["']account_is_active["']\)/);
assert.match(encounterSession, /rpc\(\s*["']can_open_encounter_session["']/);
assert.match(encounterSession, /SUPABASE_SERVICE_ROLE_KEY/);
assert.match(encounterSession, /chat_mode:\s*["']encounter["']/);
assert.match(encounterSession, /user_id:\s*user\.id/);
assert.match(encounterSession, /character_snapshot:\s*snapshot/);
assert.match(encounterSession, /snapshot\s*=\s*\{/);
assert.doesNotMatch(encounterSession, /body\.characterSnapshot|body\.userId|body\.chatMode/);
assert.match(encounterSession, /session_id_conflict/);
assert.match(accessMigration, /SECURITY DEFINER/);
assert.match(accessMigration, /SET search_path = ['"]{2}/);
assert.match(accessMigration, /private\.current_user_is_adult\(\)/);
assert.match(accessMigration, /REVOKE ALL ON FUNCTION public\.can_open_encounter_session\(uuid\) FROM PUBLIC, anon/);
assert.match(accessMigration, /GRANT EXECUTE ON FUNCTION public\.can_open_encounter_session\(uuid\) TO authenticated/);


const frontend = fs.readFileSync("index.html", "utf8");
assert.match(frontend, /async function createEncounterSession\(character\)/);
assert.match(frontend, /functions\.invoke\(["']encounter-session["']/);
assert.match(frontend, /data\.session\.chat_mode !== ["']encounter["']/);
assert.match(frontend, /encounterMode:\s*true/);
assert.match(frontend, /suggestions:\s*true,[\s\S]{0,100}background:\s*['"]avatar['"]/);
assert.match(frontend, /installSuggestionSwipe/);
assert.match(frontend, /滑動或點選燈號可切換/);
assert.match(frontend, /data-action="suggestion-select"/);
assert.match(frontend, /data-action="suggestion"/);
assert.match(frontend, /messages:\s*\[\]/);

console.log("Encounter chat-mode security guard tests passed.");
