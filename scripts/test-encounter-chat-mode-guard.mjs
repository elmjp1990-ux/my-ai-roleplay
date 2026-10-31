import assert from "node:assert/strict";
import fs from "node:fs";
import { resolveEncounterSchedule } from "../supabase/functions/_shared/encounter-schedule.mjs";

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

const frontend = fs.readFileSync("index.html", "utf8");
const encounterSession = fs.readFileSync("supabase/functions/encounter-session/index.ts", "utf8");
assert.match(frontend, /locationKey: encounterPlace/);
assert.match(frontend, /請從城市地圖的有效地標進入相遇/);
const accessMigration = fs.readFileSync("supabase/migrations/20261028180000_encounter_session_access_check.sql", "utf8");
assert.match(encounterSession, /auth\.getUser\(\)/);
assert.match(encounterSession, /rpc\(["']account_is_active["']\)/);
assert.match(encounterSession, /can_open_encounter_session/);
assert.match(encounterSession, /session_id_conflict/);
assert.match(encounterSession, /locationKey/);
assert.match(encounterSession, /resolveEncounterSchedule/);
assert.match(encounterSession, /character_schedules/);
assert.match(encounterSession, /character_not_at_this_location_now/);
const encounterSchedule = fs.readFileSync("supabase/functions/_shared/encounter-schedule.mjs", "utf8");
assert.match(encounterSchedule, /Asia\/Taipei/);
assert.match(encounterSchedule, /const dayType = row\.day_type/);
assert.match(encounterSchedule, /dayType === ["']weekday["']/);
assert.match(encounterSchedule, /dayType === ["']weekend["']/);
assert.match(encounterSchedule, /const overnight = end < start/);
assert.match(encounterSchedule, /dayOffset === -1/);
assert.match(encounterSchedule, /priority/);
assert.match(encounterSchedule, /weekdaySpecific/);
assert.match(encounterSchedule, /\(\\d\{2\}\)/);

assert.match(encounterSession, /create_encounter_session_with_lifecycle/);

assert.match(accessMigration, /private\.current_user_is_adult\(\)/);
assert.doesNotMatch(encounterSession, /\.eq\(["']latest_eligible["'],\s*true\)/);

const encounterTurn = fs.readFileSync("supabase/functions/encounter-turn/index.ts", "utf8");
assert.match(encounterTurn, /auth\.getUser\(\)/);
assert.match(encounterTurn, /session\.chat_mode !== ["']encounter["']/);
assert.match(encounterTurn, /reserve_encounter_chat_turn/);
assert.match(encounterTurn, /settle_chat_turn/);
assert.match(encounterTurn, /record_encounter_session_turn_evidence/);
assert.doesNotMatch(encounterTurn, /record_encounter_turn_interaction/);
assert.doesNotMatch(encounterTurn, /p_affinity_delta:\s*1/);
assert.match(encounterTurn, /affinityPendingUntilSceneEnd/);
assert.match(encounterTurn, /assistant_message_id_collision/);
assert.match(encounterTurn, /reserve_encounter_chat_turn/);
assert.doesNotMatch(encounterTurn, /from\(["']encounter_session_lifecycle["']\)/);
assert.match(encounterTurn, /idempotent recovery of an already-reserved pre-expiry turn/);

const atomicReservationMigration = fs.readFileSync(
  "supabase/migrations/20261031170000_atomic_encounter_turn_reservation.sql",
  "utf8",
);
assert.match(atomicReservationMigration, /FUNCTION public\.reserve_encounter_chat_turn/);
assert.match(atomicReservationMigration, /FOR UPDATE/);
assert.match(atomicReservationMigration, /l\.status <> 'active'/);
assert.match(atomicReservationMigration, /l\.scheduled_end_at <= clock_timestamp\(\)/);
assert.match(atomicReservationMigration, /public\.reserve_chat_turn\(/);
assert.match(atomicReservationMigration, /TO service_role/);
assert.match(atomicReservationMigration, /clock_timestamp\(\)/);

const preExpiryTurnMigration = fs.readFileSync(
  "supabase/migrations/20261031180000_allow_preexpiry_reserved_turn_completion.sql",
  "utf8",
);
assert.match(preExpiryTurnMigration, /c\.reserved_at <= l\.scheduled_end_at/);
assert.match(preExpiryTurnMigration, /c\.status IN \('reserved','needs_reconciliation'\)/);
assert.match(preExpiryTurnMigration, /Encounter has pending pre-expiry turns/);
assert.match(preExpiryTurnMigration, /l\.status NOT IN \('active','paused','ready_to_settle'\)/);
assert.match(preExpiryTurnMigration, /FOR UPDATE/);

const preExpiryRetryMigration = fs.readFileSync(
  "supabase/migrations/20261031200000_allow_preexpiry_encounter_retry.sql",
  "utf8",
);
assert.match(preExpiryRetryMigration, /c\.status IN \('reserved','needs_reconciliation','settled','refunded'\)/);
assert.match(preExpiryRetryMigration, /c\.reserved_at <= l\.scheduled_end_at/);
assert.match(preExpiryRetryMigration, /c\.status='insufficient_funds'/);
assert.match(preExpiryRetryMigration, /l\.status <> 'active'/);
assert.match(preExpiryRetryMigration, /l\.scheduled_end_at <= clock_timestamp\(\)/);
assert.match(preExpiryRetryMigration, /public\.reserve_chat_turn\(/);

const retryChargeLookupMigration = fs.readFileSync(
  "supabase/migrations/20261031210000_fix_encounter_retry_charge_lookup.sql",
  "utf8",
);
assert.match(retryChargeLookupMigration, /charge\.turn_id=p_turn_id/);
assert.match(retryChargeLookupMigration, /c\.status IN \('reserved','needs_reconciliation','settled','refunded'\)/);
assert.match(retryChargeLookupMigration, /c\.reserved_at <= l\.scheduled_end_at/);
assert.match(retryChargeLookupMigration, /l\.scheduled_end_at <= clock_timestamp\(\)/);
assert.match(retryChargeLookupMigration, /turn_id_reuse_conflict/);

const retryLifecycleMigration = fs.readFileSync(
  "supabase/migrations/20261031220000_restrict_encounter_retry_lifecycle_states.sql",
  "utf8",
);
assert.match(retryLifecycleMigration, /l\.status NOT IN \('active','paused','ready_to_settle'\)/);
assert.match(retryLifecycleMigration, /c\.reserved_at <= l\.scheduled_end_at/);
assert.match(retryLifecycleMigration, /l\.scheduled_end_at <= clock_timestamp\(\)/);
assert.match(retryLifecycleMigration, /turn_id_reuse_conflict/);

const storyBatchSourcesMigration = fs.readFileSync(
  "supabase/migrations/20261031230000_validate_story_batch_turn_sources.sql",
  "utf8",
);
assert.match(storyBatchSourcesMigration, /cardinality\(NEW\.source_turn_ids\) <> v_expected_count/);
assert.match(storyBatchSourcesMigration, /count\(DISTINCT source_id\)/);
assert.match(storyBatchSourcesMigration, /charge\.session_id=NEW\.session_id/);
assert.match(storyBatchSourcesMigration, /charge\.user_id=NEW\.user_id/);
assert.match(storyBatchSourcesMigration, /charge\.status='settled'/);

const evaluationDispatchMigration = fs.readFileSync(
  "supabase/migrations/20261031240000_encounter_evaluation_dispatch_queue.sql",
  "utf8",
);
assert.match(evaluationDispatchMigration, /FUNCTION public\.enqueue_due_encounter_evaluations/);
assert.match(evaluationDispatchMigration, /FUNCTION public\.claim_encounter_evaluation_jobs/);
assert.match(evaluationDispatchMigration, /FUNCTION public\.fail_encounter_evaluation_job/);
assert.match(evaluationDispatchMigration, /FOR UPDATE SKIP LOCKED/);
assert.match(evaluationDispatchMigration, /Encounter evaluation job session link is invalid/);
assert.match(evaluationDispatchMigration, /cron\.schedule/);
assert.match(evaluationDispatchMigration, /CREATE EXTENSION IF NOT EXISTS pg_cron/);
assert.match(evaluationDispatchMigration, /status='ready_to_settle'/);
assert.match(evaluationDispatchMigration, /status IN \('created','reserved','needs_reconciliation'\)/);

const evaluationRetryMigration = fs.readFileSync(
  "supabase/migrations/20261031250000_bound_encounter_evaluation_retries.sql",
  "utf8",
);
assert.match(evaluationRetryMigration, /attempt_count < 5/);
assert.match(evaluationRetryMigration, /interval '5 minutes'/);
assert.match(evaluationRetryMigration, /interval '10 minutes'/);

const pauseResumeMigration = fs.readFileSync(
  "supabase/migrations/20261031190000_encounter_session_pause_resume.sql",
  "utf8",
);
const pauseResumeEndpoint = fs.readFileSync(
  "supabase/functions/encounter-session-state/index.ts",
  "utf8",
);
assert.match(pauseResumeMigration, /FUNCTION public\.set_encounter_session_lifecycle_state/);
assert.match(pauseResumeMigration, /FOR UPDATE/);
assert.match(pauseResumeMigration, /p_action='pause'/);
assert.match(pauseResumeMigration, /p_action NOT IN \(['"]pause['"],['"]resume['"]\)/);
assert.match(pauseResumeMigration, /scheduled_end_at <= clock_timestamp/);
assert.match(pauseResumeMigration, /TO service_role/);
assert.match(pauseResumeEndpoint, /auth.getUser/);
assert.match(pauseResumeEndpoint, /account_is_active/);
assert.match(pauseResumeEndpoint, /set_encounter_session_lifecycle_state/);
assert.match(pauseResumeEndpoint, /encounter_scene_expired_or_closed/);
assert.match(pauseResumeEndpoint, /p_user_id: user\.id/);

assert.match(frontend, /async function setEncounterLifecycleState\(sessionId, action\)/);
assert.match(frontend, /functions\.invoke\(['"]encounter-session-state['"]/);
assert.match(frontend, /setEncounterLifecycleState\(session\.id,'pause'\)/);
assert.match(frontend, /setEncounterLifecycleState\(resumedSession\.id,'resume'\)/);
assert.match(frontend, /const saved=await saveChatSessionSafely\(encounterSession\)/);
assert.match(frontend, /encounter_scene_expired_or_closed/);


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
assert.equal((affinityMigration.match(/AS \$\$/g) || []).length, 5);
assert.equal((affinityMigration.match(/^\$\$;$/gm) || []).length, 5);
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



const evidenceMigration = fs.readFileSync("supabase/migrations/20261031120000_encounter_turn_evidence_writer.sql", "utf8");
assert.match(evidenceMigration, /c\.status <> ['"]settled['"]/);
assert.match(evidenceMigration, /c\.session_id IS DISTINCT FROM p_session_id/);
assert.match(evidenceMigration, /c\.user_id IS DISTINCT FROM p_user_id/);
assert.match(evidenceMigration, /um\.session_id IS DISTINCT FROM p_session_id/);
assert.match(evidenceMigration, /am\.session_id IS DISTINCT FROM p_session_id/);
assert.match(evidenceMigration, /FOR UPDATE/);
assert.match(evidenceMigration, /turn_count=n/);
assert.match(evidenceMigration, /REVOKE ALL ON FUNCTION public\.record_encounter_session_turn_evidence/);
assert.match(evidenceMigration, /GRANT EXECUTE ON FUNCTION public\.record_encounter_session_turn_evidence[^;]*TO service_role/s);



const expiredTurnMigration = fs.readFileSync(
  "supabase/migrations/20261031160000_block_expired_encounter_turns.sql",
  "utf8",
);
assert.match(expiredTurnMigration, /l\.scheduled_end_at <= now\(\)/);
assert.match(expiredTurnMigration, /Invalid or expired Encounter lifecycle/);

const settlementMigration = fs.readFileSync(
  "supabase/migrations/20261031150000_encounter_scene_settlement.sql",
  "utf8",
);
assert.match(settlementMigration, /l\.scheduled_end_at > now\(\)/);
assert.match(settlementMigration, /l\.status NOT IN \(['"]active['"],['"]paused['"],['"]ready_to_settle['"]\)/);
assert.match(settlementMigration, /FOR UPDATE/);
assert.match(settlementMigration, /l\.status='settled'/);
assert.match(settlementMigration, /idempotent',true/);
assert.match(settlementMigration, /greatest\(-100,least\(100,v_current\+p_affinity_delta\)\)/);
assert.match(settlementMigration, /encounter_session_turns t WHERE t\.session_id=p_session_id/);
assert.match(settlementMigration, /REVOKE ALL ON FUNCTION public\.settle_encounter_session/);
assert.match(settlementMigration, /GRANT EXECUTE ON FUNCTION public\.settle_encounter_session[^;]*TO service_role/s);

const schedule = (overrides = {}) => ({
  id: "schedule-1", weekday: null, day_type: "any",
  start_time: "09:00:00", end_time: "18:00:00",
  location_key: "cafe", activity: "工作", priority: 1, is_active: true,
  ...overrides,
});
const at = (iso, rows = [schedule()], place = "cafe") =>
  resolveEncounterSchedule(rows, place, new Date(iso));

// Weekday matching, inclusive start, exclusive end, and saved Taiwan offset.
const fridayStart = at("2026-10-30T01:00:00.000Z", [schedule({ weekday: 5, day_type: "weekday" })]);
assert.ok(fridayStart, "weekday schedule should match at its start boundary");
assert.equal(fridayStart.scheduleSnapshot.timezone, "Asia/Taipei");
assert.equal(fridayStart.scheduledStartAt, "2026-10-30T01:00:00.000Z");
assert.equal(at("2026-10-30T10:00:00.000Z"), null, "end boundary must be exclusive");

// Weekend/weekday day_type filters apply to the schedule start date.
assert.ok(at("2026-10-31T01:00:00.000Z", [schedule({ day_type: "weekend" })]));
assert.equal(at("2026-10-31T01:00:00.000Z", [schedule({ day_type: "weekday" })]), null);
assert.equal(at("2026-10-30T01:00:00.000Z", [schedule({ day_type: "weekend" })]), null);

// Overnight schedules retain the previous day's weekday/day_type after midnight.
const overnight = at("2026-10-30T17:00:00.000Z", [
  schedule({ weekday: 5, day_type: "weekday", start_time: "22:00:00", end_time: "02:00:00" }),
]);
assert.ok(overnight, "Friday overnight schedule should match Saturday 01:00 Taiwan time");
assert.equal(overnight.scheduledStartAt, "2026-10-30T14:00:00.000Z");
assert.equal(overnight.scheduledEndAt, "2026-10-30T18:00:00.000Z");
assert.equal(at("2026-10-30T18:00:00.000Z", [
  schedule({ weekday: 5, start_time: "22:00", end_time: "02:00" }),
]), null, "overnight end boundary must be exclusive");

// Higher priority wins; weekday-specific wins only when priorities tie.
const prioritized = at("2026-10-30T02:00:00.000Z", [
  schedule({ id: "generic", priority: 8 }),
  schedule({ id: "weekday", weekday: 5, day_type: "weekday", priority: 3 }),
]);
assert.equal(prioritized.scheduleSnapshot.schedule_id, "generic");
const specificityTie = at("2026-10-30T02:00:00.000Z", [
  schedule({ id: "generic", priority: 8 }),
  schedule({ id: "weekday", weekday: 5, day_type: "weekday", priority: 8 }),
]);
assert.equal(specificityTie.scheduleSnapshot.schedule_id, "weekday");

// Reject wrong location, inactive rows, invalid clocks, zero-length and invalid day types.
assert.equal(at("2026-10-30T02:00:00.000Z", [schedule()], "park"), null);
assert.equal(at("2026-10-30T02:00:00.000Z", [schedule({ is_active: false })]), null);
assert.equal(at("2026-10-30T02:00:00.000Z", [schedule({ start_time: "25:00", end_time: "26:00" })]), null);
assert.equal(at("2026-10-30T02:00:00.000Z", [schedule({ start_time: "09:00", end_time: "09:00" })]), null);
assert.equal(at("2026-10-30T02:00:00.000Z", [schedule({ day_type: "holiday" })]), null);

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

assert.match(storySession, /relationshipState/);
assert.match(storySession, /relationship: relationshipState/);
assert.match(frontend, /async function openNewStoryDialog\(characterId\)/);
assert.match(frontend, /get_latest_settled_encounter_session/);
assert.match(frontend, /data-action="start-new-story"/);
assert.match(frontend, /data-action="story-start-mode"/);
assert.match(frontend, /async function createStorySession\(characterId, originMode/);
assert.match(frontend, /functions\.invoke\('story-session'/);
assert.match(frontend, /storyRelationshipStage/);
const latestStorySourceMigration = fs.readFileSync(
  "supabase/migrations/20261031260000_latest_settled_encounter_for_story.sql",
  "utf8",
);
assert.match(latestStorySourceMigration, /auth\.uid\(\)/);
assert.match(latestStorySourceMigration, /lifecycle\.user_id=v_user_id/);
assert.match(latestStorySourceMigration, /lifecycle\.character_id=p_character_id/);
assert.match(latestStorySourceMigration, /lifecycle\.status='settled'/);
assert.match(latestStorySourceMigration, /GRANT EXECUTE ON FUNCTION public\.get_latest_settled_encounter_session\(uuid\) TO authenticated/);
assert.match(affinityMigration, /FUNCTION public\.create_story_session_with_relationship/);
assert.match(affinityMigration, /GRANT EXECUTE ON FUNCTION public\.create_story_session_with_relationship/);
assert.match(affinityMigration, /FUNCTION public\.create_encounter_session_with_lifecycle/);
assert.match(affinityMigration, /INSERT INTO public\.encounter_session_lifecycle/);
assert.match(affinityMigration, /GRANT EXECUTE ON FUNCTION public\.create_encounter_session_with_lifecycle/);

assert.match(affinityMigration, /INSERT INTO public\.story_relationship_states/);
