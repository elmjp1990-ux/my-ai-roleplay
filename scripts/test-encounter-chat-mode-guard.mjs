import assert from "node:assert/strict";
import fs from "node:fs";

const chatTurn = fs.readFileSync("supabase/functions/chat-turn/index.ts", "utf8");
const modeMigration = fs.readFileSync("supabase/migrations/20261028170000_trusted_chat_mode_marker.sql", "utf8");
const guardMigration = fs.readFileSync("supabase/migrations/20261028173000_enforce_trusted_chat_mode.sql", "utf8");

assert.match(chatTurn, /select\(["']id,user_id,deleted_at,character_id,(?:character_name,)?character_snapshot,(?:session_data,)?chat_mode["']\)/);
assert.match(chatTurn, /session\.chat_mode\s*===\s*["']encounter["']/);
assert.match(chatTurn, /encounter_turn_handler_required/);
assert.match(chatTurn, /session\.chat_mode\s*!==\s*["']story["']/);
assert.match(modeMigration, /ADD COLUMN IF NOT EXISTS chat_mode text NOT NULL DEFAULT ['"]story['"]/);
assert.match(modeMigration, /CHECK \(chat_mode IN \(['"]story['"], ['"]encounter['"]\)\)/);
assert.match(guardMigration, /SECURITY DEFINER/);
assert.match(guardMigration, /SET search_path = ['"]{2}/);
assert.match(guardMigration, /NEW\.chat_mode IS DISTINCT FROM OLD\.chat_mode/);

const frontend = fs.readFileSync("index.html", "utf8");
const cityMap = fs.readFileSync("city-map.js", "utf8");
assert.doesNotMatch(frontend, /data-action="start-new-story"/);
assert.ok(frontend.includes('const sessionId = options.id || id();'));
assert.ok(frontend.includes('state.sessions[sessionId] = session;'));
assert.match(frontend, /function compactLocalStateForQuota\(sourceState = state\)/);
assert.match(frontend, /localStorageCompactMode = true/);
assert.match(frontend, /雲端聊天仍會照常同步/);
assert.match(frontend, /character\\?\\.visibility!==['\"]public['\"]\\|\\|character\\.deletedAt\\|\\|!accessible\\(character\\)/);
assert.match(cityMap, /Author access to a private character is for management only/);

assert.ok(frontend.includes("Object.prototype.hasOwnProperty.call(priorSnapshot,'authorId') && priorSnapshot.authorId !== ''"));
assert.ok(frontend.includes("snapshot.authorId === null || isUuid(snapshot.authorId)"));
assert.ok(frontend.includes("Object.prototype.hasOwnProperty.call(canonical,'authorId') && canonical.authorId !== ''"));
assert.ok(frontend.includes("Object.prototype.hasOwnProperty.call(snap,'authorId') ? snap.authorId : ''"));
assert.ok(frontend.includes("creatorDisplayName:priorSnapshot.creatorDisplayName || character?.creatorDisplayName || ''"));
assert.ok(frontend.includes("creatorHandleSnapshot:priorSnapshot.creatorHandleSnapshot || character?.creatorHandleSnapshot || ''"));
assert.ok(frontend.includes("authorId:snapshot.authorId"));
assert.ok(frontend.includes("creatorDisplayName:snapshot.creatorDisplayName ?? existingCharacter.creatorDisplayName ?? ''"));
assert.ok(frontend.includes("BY ${e(creatorAttribution)}"));
assert.ok(frontend.includes("c.authorId ? `<button class=\"author-link\""));

assert.doesNotMatch(frontend, /const cityScheduleCache=new Map\(\)/);
assert.match(frontend, /async function loadCityCharacterSchedules/);
assert.match(frontend, /get_encounter_character_schedules/);
assert.match(frontend, /if\(error\)throw new Error\('讀取角色行程失敗：'\+error\.message\)/);
assert.match(cityMap, /person\.encounterSchedules=schedules\.get\(person\.id\)\|\|''/);
assert.doesNotMatch(cityMap, /hydrateCitySchedule/);
assert.match(cityMap, /const isCurrentCityCharacterEligible=\(person\)=>/);
assert.match(cityMap, /isCurrentCityCharacterEligible\(person\)/);
assert.match(frontend, /async function startChat\(characterId\)/);
assert.match(frontend, /find_existing_story_chat_session/);
const queryOptimizationMigration = fs.readFileSync("supabase/migrations/20261114200000_batch_character_story_and_encounter_schedule_reads.sql", "utf8");
assert.match(queryOptimizationMigration, /s\.user_id = \(SELECT auth\.uid\(\)\)/);
assert.match(queryOptimizationMigration, /LIMIT 10/);
assert.match(queryOptimizationMigration, /SECURITY INVOKER/);
assert.match(frontend, /get_latest_settled_encounter_session/);
assert.match(frontend, /代入相遇好感度/);
assert.match(frontend, /開啟全新故事/);
assert.match(frontend, /await openNewStoryDialog\(characterId, latestEncounter \\|\\| null\)/);
assert.match(frontend, /目前沒有已結算的相遇紀錄，暫時無法代入/);
assert.match(frontend, /if \(!saved\) throw new Error\('新故事已建立/);
const encounterSession = fs.readFileSync("supabase/functions/encounter-session/index.ts", "utf8");
assert.match(frontend, /locationKey: encounterPlace/);
assert.match(frontend, /請從城市地圖的有效地標進入相遇/);
const accessMigration = fs.readFileSync("supabase/migrations/20261028180000_encounter_session_access_check.sql", "utf8");
assert.match(encounterSession, /auth\.getUser\(\)/);
assert.match(encounterSession, /rpc\(["']account_is_active["']\)/);
assert.match(encounterSession, /can_open_encounter_session/);
assert.match(encounterSession, /session_id_conflict/);
assert.match(encounterSession, /locationKey/);
assert.match(encounterSession, /rpc\(\s*["']resolve_encounter_character_schedule_with_scene["']/);
assert.match(encounterSession, /p_location_key: locationKey/);
assert.match(encounterSession, /scheduleSnapshot = \{/);
assert.doesNotMatch(encounterSession, /\.from\(["']character_schedules["']\)/);
assert.match(encounterSession, /character_not_at_this_location_now/);
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
assert.match(encounterTurn, /charge\.status === "settled" \|\| charge\.status === "needs_reconciliation"/);
assert.match(encounterTurn, /provider_generation_outcome_unknown/);
assert.match(encounterTurn, /generation_already_claimed/);
assert.match(encounterTurn, /refundEncounterTurn/);
assert.doesNotMatch(encounterTurn, /demoReply/);
assert.match(encounterTurn, /encounterSchedule/);
assert.doesNotMatch(encounterTurn, /from\(["']encounter_session_lifecycle["']\)/);
assert.match(encounterSession, /snapshot\.encounterSchedule = scheduleSnapshot/);

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
assert.match(cityMap, /setEncounterLifecycleState\(resumedSession\.id,'resume'\)/);
assert.match(cityMap, /const saved=await saveChatSessionSafely\(encounterSession\)/);
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
assert.ok(frontend.includes("function loadEncounterMemoryList(panel,session)"));
assert.match(frontend, /encounter_place:session_data->>encounterPlace/);
assert.match(frontend, /相遇地點：/);
assert.match(frontend, /canSavePrecreatedSession = s\.cloudOwned === true/);
assert.match(frontend, /s\.encounterMode === true \|\| s\.storyMode === true/);
assert.match(frontend, /if \(!hasUserMessage && !canSavePrecreatedSession\) return false;/);
assert.match(frontend, /from\(["']encounter_diary["']\)/);
assert.match(frontend, /async function openEncounterMemoryDetail\(button\)/);
assert.match(frontend, /data-action="encounter-memory-open"/);
assert.match(frontend, /相遇日記/);
assert.match(frontend, /故事模式記憶混合/);
assert.match(frontend, /chatOverlay:\'encounter-dialogues\'/);
assert.match(frontend, /aria-label="本次對話紀錄"/);
assert.match(frontend, /function showEncounterLeaveDialog\(session\)/);
assert.match(frontend, /data-action="encounter-temporary-leave"/);
assert.match(frontend, /data-action="encounter-end-confirm"/);
assert.match(frontend, /activeEncounter\?\.encounterMode===true\)\{showEncounterLeaveDialog/);
assert.match(cityMap, /findResumableEncounterSession\(person\.id,placeKey\)/);
assert.match(frontend, /encounterDay/);
assert.match(frontend, /encounter-dialog-dismiss/);
assert.match(frontend, /saved!==true\)throw new Error\('雲端未確認儲存結果。'\)/);
assert.match(frontend, /\.eq\(["']chat_mode["'],["']encounter["']\)/);
assert.match(frontend, /item\.characterId === c\.id && !item\.archived && !isEncounterChatSession\(item\)/);
assert.match(frontend, /const hasConversation=hasUserMessage\(s\)\|\|\(s\.cloudOwned&&s\.cloudHasUserMessage==null\)/);
assert.match(frontend, /session_encounter_metadata:session_data->encounter/);
assert.match(frontend, /function isEncounterChatSession\(session\)/);
assert.match(frontend, /session\?\.chatMode==='encounter'/);
assert.match(frontend, /data\.encounter&&typeof data\.encounter==='object'/);
assert.match(frontend, /session\?\.chat_mode==='encounter'/);
assert.match(frontend, /data\.encounterMode===true/);
assert.match(frontend, /data\.chatMode==='encounter'/);
assert.match(frontend, /data\.chat_mode==='encounter'/);
assert.match(frontend, /data\.encounterPlace==='string'/);
assert.match(frontend, /const encounterPlace=session\?\.encounterPlace\|\|data\.encounterPlace/);
assert.match(queryOptimizationMigration, /s\.session_data ->> 'encounterMode'/);
assert.match(queryOptimizationMigration, /s\.session_data ->> 'encounterPlace'/);
assert.match(queryOptimizationMigration, /jsonb_typeof\(s\.session_data -> 'encounter'\) IS DISTINCT FROM 'object'/);
assert.match(queryOptimizationMigration, /s\.chat_mode <> 'encounter'/);
assert.match(frontend, /const seenCharacters=new Set\(\)/);
assert.match(frontend, /const characterId=session\.characterId\|\|sessionCharacter\(session\)\?\.id\|\|session\.id/);
assert.match(frontend, /function formatMessage\(text\)[\s\S]*?\[\\s\\S\]\+\?/);
assert.match(frontend, /\.suggestion-first-message-hint \{ box-sizing:border-box; width:100%; margin:0; padding:7px 9px 9px; color:var\(--muted\); text-align:center; font-size:10px;/);
assert.match(frontend, /!isEncounterChatSession\(s\)/);
assert.match(frontend, /session_encounter_metadata:session_data->encounter/);
assert.match(frontend, /row\.session_encounter_metadata\s*&&\s*typeof\s+row\.session_encounter_metadata\s*===\s*'object'/);
assert.match(frontend, /!isEncounterChatSession\(item\)/);
assert.match(frontend, /!isEncounterChatSession\(candidate\)/);
assert.match(frontend, /if \(!item \|\| !canAccessSessionCharacter\(item,sessionCharacter\(item\)\)\) break;/);
assert.match(frontend, /item\.id !== s\.id && item\.characterId === c\.id && !item\.archived && !isEncounterChatSession\(item\)/);
assert.match(frontend, /candidate\.id!==item\.id&&candidate\.characterId===item\.characterId&&!candidate\.archived&&!isEncounterChatSession\(candidate\)/);
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

const schedulePipeline = fs.readFileSync("supabase/drafts/encounter-schedule-pipeline.sql", "utf8");
assert.match(schedulePipeline, /FUNCTION public\.resolve_encounter_character_schedule/);
assert.match(schedulePipeline, /AT TIME ZONE ['"]Asia\/Taipei['"]/);
assert.match(schedulePipeline, /s\.start_time > s\.end_time/);
assert.match(schedulePipeline, /v_schedule_date := CASE/);
assert.match(schedulePipeline, /day_type = 'holiday'/);
assert.match(schedulePipeline, /get_encounter_city_weather\(\)/);
assert.match(schedulePipeline, /rain_fallback_location_key/);

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
assert.match(frontend, /async function openNewStoryDialog\(characterId, latest = null\)/);
assert.match(frontend, /get_latest_settled_encounter_session/);
assert.doesNotMatch(frontend, /data-action="start-new-story"/);
assert.match(frontend, /data-action="story-start-mode"/);
assert.match(frontend, /async function createStorySession\(characterId, originMode/);
assert.match(frontend, /functions\.invoke\('story-session'/);
assert.match(frontend, /storyRelationshipStage/);

assert.match(frontend, /canSavePrecreatedSession/);
assert.match(frontend, /s\.storyMode === true/);
assert.match(frontend, /開啟新故事/);
assert.ok(
  storySession.indexOf("A retry may only retrieve") < storySession.indexOf("character_can_start_chat"),
  "Idempotent Story session recovery must be checked before new-character access eligibility",
);
const latestStorySourceMigration = fs.readFileSync(
  "supabase/migrations/20261031260000_latest_settled_encounter_for_story.sql",
  "utf8",
);
assert.match(latestStorySourceMigration, /auth\.uid\(\)/);
assert.match(latestStorySourceMigration, /lifecycle\.user_id=v_user_id/);
assert.match(latestStorySourceMigration, /lifecycle\.character_id=p_character_id/);
assert.match(latestStorySourceMigration, /lifecycle\.status='settled'/);
assert.match(latestStorySourceMigration, /GRANT EXECUTE ON FUNCTION public\.get_latest_settled_encounter_session\(uuid\) TO authenticated/);

const storyRelationshipReadMigration = fs.readFileSync(
  "supabase/migrations/20261031270000_story_relationship_state_read_rpc.sql",
  "utf8",
);
assert.match(storyRelationshipReadMigration, /auth\.uid\(\)/);
assert.match(storyRelationshipReadMigration, /state\.user_id=v_user_id/);
assert.match(storyRelationshipReadMigration, /session\.chat_mode='story'/);
assert.match(storyRelationshipReadMigration, /GRANT EXECUTE ON FUNCTION public\.get_story_relationship_state\(uuid\) TO authenticated/);
assert.match(frontend, /async function loadStoryRelationshipState\(session\)/);
assert.match(frontend, /get_story_relationship_state/);
assert.match(frontend, /storyRelationshipLabel/);
assert.match(frontend, /story-relationship-meter/);
assert.match(cityMap, /get_latest_settled_encounter_affinity/);
assert.match(frontend, /city-character-affinity/);
assert.match(cityMap, /你們還不認識/);
assert.match(cityMap, /登入後查看與角色的好感度/);
assert.match(cityMap, /loadCityCharacterAffinity\(person.id\)/);
assert.match(frontend, /city-character-affinity-meter/);
assert.match(affinityMigration, /FUNCTION public\.create_story_session_with_relationship/);
assert.match(affinityMigration, /GRANT EXECUTE ON FUNCTION public\.create_story_session_with_relationship/);
assert.match(affinityMigration, /FUNCTION public\.create_encounter_session_with_lifecycle/);
assert.match(affinityMigration, /INSERT INTO public\.encounter_session_lifecycle/);
assert.match(affinityMigration, /GRANT EXECUTE ON FUNCTION public\.create_encounter_session_with_lifecycle/);

assert.match(affinityMigration, /INSERT INTO public\.story_relationship_states/);


// Existing empty Story sessions must be reused instead of creating duplicates.
assert.ok(frontend.includes("client.rpc('find_existing_story_chat_session'"));

const encounterPresentation = fs.readFileSync("encounter-scene.js", "utf8");
const encounterHistory = fs.readFileSync("encounter-history.js", "utf8");
assert.match(encounterHistory, /loadCloudHistory/);
assert.match(encounterHistory, /eq\(['"]chat_mode['"],['"]encounter['"]\)[\s\S]*?limit\(2\)/);
assert.match(encounterHistory, /正在讀取雲端相遇紀錄/);
assert.match(encounterPresentation, /playerTurns===0/);
assert.match(encounterPresentation, /先跟'\+characterName\+'打招呼/);
assert.match(encounterPresentation, /留空發送，角色會繼續說下去/);
assert.match(encounterPresentation, /window\.visualViewport/);
assert.match(encounterPresentation, /height:100lvh!important/);
assert.match(encounterPresentation, /neutralBackdrop/);
assert.match(encounterPresentation, /brightness>=158&&spread<=36/);
assert.match(encounterPresentation, /encounter-auto-bg-fallback\{mix-blend-mode:normal!important/);
assert.match(encounterPresentation, /body\.encounter-mode-active \.chat-main\.encounter-scene>\.chat-heading/);
assert.match(encounterPresentation, /processEncounterSpriteBackdrop/);
assert.match(encounterPresentation, /panel\.clientHeight-\(viewport\.height\+viewport\.offsetTop\)/);
assert.match(encounterPresentation, /bottom:var\(--encounter-keyboard-offset,0px\)!important/);
