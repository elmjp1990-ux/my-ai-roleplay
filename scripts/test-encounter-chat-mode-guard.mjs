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
assert.match(frontend, /async function loadEncounterMemoryList\(panel,session\)/);
assert.match(frontend, /sessionData\.encounterPlace/);
assert.match(frontend, /相遇地點：/);
assert.match(frontend, /canSaveEncounterMetadata = s\.encounterMode === true && s\.cloudOwned === true/);
assert.match(frontend, /if \(!hasUserMessage && !canSaveEncounterMetadata\) return false;/);
assert.match(frontend, /from\(["']encounter_diary["']\)/);
assert.match(frontend, /async function openEncounterMemoryDetail\(button\)/);
assert.match(frontend, /data-action="encounter-memory-open"/);
assert.match(frontend, /相遇回憶/);
assert.match(frontend, /故事模式記憶混合/);
assert.match(frontend, /chatOverlay:\'encounter-dialogues\'/);
assert.match(frontend, /aria-label="本次對話紀錄"/);
assert.match(frontend, /function showEncounterLeaveDialog\(session\)/);
assert.match(frontend, /data-action="encounter-temporary-leave"/);
assert.match(frontend, /data-action="encounter-end-confirm"/);
assert.match(frontend, /activeEncounter\?\.encounterMode===true\)\{showEncounterLeaveDialog/);
assert.match(frontend, /findResumableEncounterSession\(person\.id,placeKey\)/);
assert.match(frontend, /encounterDay/);
assert.match(frontend, /if\(isNewEncounter && sessionData\.archived!==true\)groups\.delete\(groupKey\)/);
assert.match(frontend, /encounter-dialog-dismiss/);
assert.match(frontend, /saved!==true\)throw new Error\('雲端未確認儲存結果。'\)/);
assert.match(frontend, /\.eq\(["']chat_mode["'],["']encounter["']\)/);
assert.match(frontend, /item\.characterId === c\.id && !item\.archived && item\.encounterMode !== true/);
assert.match(frontend, /return c && !s\.encounterMode && !s\.archived && hasUserMessage\(s\) &&/);
assert.match(frontend, /if \(!item \|\| item\.hidden \|\| item\.encounterMode === true\) return false;/);
assert.match(frontend, /item\.id !== s\.id && item\.characterId === c\.id && !item\.archived && item\.encounterMode !== true/);
assert.match(frontend, /candidate\.id!==item\.id&&candidate\.characterId===item\.characterId&&!candidate\.archived&&candidate\.encounterMode!==true/);
assert.match(frontend, /route\.page === 'citymap' \? 'home'/);
assert.match(frontend, /\['citymap','探索'\]/);
assert.match(frontend, /ICON\[page === 'citymap' \? 'home' : page\]/);
assert.match(frontend, /case 'home':go\(\{page:'citymap'\}\);break;/);

const affinityMigration = fs.readFileSync(
  "supabase/migrations/20261030120000_affinity_system_foundation.sql",
  "utf8",
);
assert.match(affinityMigration, /CHECK \(affinity BETWEEN -100 AND 100\)/);
assert.equal((affinityMigration.match(/AS \$\$/g) || []).length, 4);
assert.equal((affinityMigration.match(/^\$\$;$/gm) || []).length, 4);
assert.match(affinityMigration, /ON DELETE SET NULL/);
assert.match(affinityMigration, /REVOKE ALL ON TABLE public\.story_relationship_states FROM PUBLIC, anon, authenticated/);
assert.match(affinityMigration, /REVOKE ALL ON TABLE public\.encounter_session_turns FROM PUBLIC, anon, authenticated/);
assert.match(affinityMigration, /validate_affinity_session_link/);
assert.match(affinityMigration, /Affinity session owner mismatch/);
assert.match(affinityMigration, /Encounter lifecycle requires an Encounter session/);
assert.match(affinityMigration, /Story relationship requires a Story session/);
assert.match(affinityMigration, /validate_encounter_turn_evidence/);
assert.match(affinityMigration, /Encounter user message does not belong to the session/);
assert.match(affinityMigration, /Encounter assistant message does not belong to the session/);
assert.match(affinityMigration, /Encounter turn charge does not match session owner/);
assert.match(affinityMigration, /validate_story_relationship_origin/);
assert.match(affinityMigration, /Encounter snapshot source is invalid or not settled/);
assert.match(affinityMigration, /source_encounter_session_id uuid REFERENCES public\.encounter_session_lifecycle\(session_id\) ON DELETE SET NULL/);
assert.match(affinityMigration, /A carried-over Story must reference a settled Encounter/);

console.log("Encounter chat-mode, affinity schema, and Story session guard tests passed.");

const storySession = fs.readFileSync("supabase/functions/story-session/index.ts", "utf8");
assert.match(storySession, /auth\.getUser\(\)/);
assert.match(storySession, /rpc\(["']account_is_active["']\)/);
assert.match(storySession, /character_can_start_chat/);
assert.match(storySession, /originMode === ["']encounter_snapshot["']/);
assert.match(storySession, /source\.status !== ["']settled["']/);
assert.match(storySession, /result\.final_affinity/);
assert.match(storySession, /story_session_incomplete/);
assert.match(storySession, /create_story_session_with_relationship/);
assert.match(storySession, /session_id_conflict/);
assert.match(affinityMigration, /FUNCTION public\.create_story_session_with_relationship/);
assert.match(affinityMigration, /GRANT EXECUTE ON FUNCTION public\.create_story_session_with_relationship/);
assert.match(affinityMigration, /INSERT INTO public\.story_relationship_states/);
