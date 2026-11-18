import assert from "node:assert/strict";
import fs from "node:fs";

const worker = fs.readFileSync("supabase/functions/encounter-schedule-organizer/index.ts", "utf8");
const pipeline = fs.readFileSync("supabase/drafts/encounter-schedule-pipeline.sql", "utf8");
const batchSemantics = fs.readFileSync("supabase/migrations/20261117133525_encounter_schedule_batch_semantics.sql", "utf8");
const html = fs.readFileSync("index.html", "utf8");
const generator = fs.readFileSync("supabase/functions/_shared/encounter-schedule-generation.ts", "utf8");
const sparseScheduleMigration = fs.readFileSync("supabase/migrations/20261118074655_encounter_schedules_allow_unavailable_windows.sql", "utf8");
const publishedSceneResolverMigration = fs.readFileSync("supabase/migrations/20261118074708_resolve_only_published_encounter_scenes.sql", "utf8");
const sceneDescriptionMigration = fs.readFileSync("supabase/migrations/20261118074713_encounter_schedule_scene_descriptions.sql", "utf8");
const hourlyScheduleMigration = fs.readFileSync("supabase/migrations/20261118074718_encounter_hourly_schedule_options.sql", "utf8");
const pendingPriorityMigration = fs.readFileSync("supabase/migrations/20261118074723_prioritize_pending_encounter_schedule_jobs.sql", "utf8");
const rawOutputRepairMigration = fs.readFileSync("supabase/migrations/20261118074727_encounter_schedule_raw_output_repair.sql", "utf8");
const rawOutputRepairReplay = fs.readFileSync("supabase/drafts/replay-encounter-schedule-output-repair.sql", "utf8");
const providerAdapter = fs.readFileSync("supabase/functions/_shared/openrouter-chat-completions.ts", "utf8");
const replayWorkflow = fs.readFileSync(".github/workflows/supabase-local-migration-replay.yml", "utf8");
const weatherWorker = fs.readFileSync("supabase/functions/encounter-weather-sync/index.ts", "utf8");
const weatherParser = fs.readFileSync("supabase/functions/_shared/encounter-weather.mjs", "utf8");

assert.match(worker, /requestOpenRouterChatCompletion/);
assert.match(worker, /POYOZZ_DEFAULT_CHAT_MODEL/);
assert.match(worker, /claim_encounter_schedule_batch/);
assert.match(worker, /publish_encounter_schedule_batch/);
assert.match(worker, /fail_encounter_schedule_batch/);
assert.match(worker, /parseEncounterScheduleBatchOutput/);
assert.match(worker, /recordRawGenerationOutput/);
assert.match(worker, /handleScheduleRepair/);
assert.match(worker, /mode === "repair_list"/);
assert.match(worker, /claim_encounter_schedule_repair/);
assert.match(worker, /eq\("actor_user_id", actorUserId\)/);
assert.match(worker, /originalBatch\.is_manual !== true/);
assert.match(worker, /job\.source_hash !== output\.source_hash/);
assert.match(worker, /delete\(\)\.lt\("expires_at"/);
assert.match(worker, /repairableCharacterIds/);
assert.match(worker, /job\.status === "failed"/);
assert.match(worker, /updateRawGenerationOutput\(admin, rawOutputIdByCharacter\.get\(item\.sourceId\)[\s\S]*?"completed"/);

assert.match(worker, /updateRawGenerationOutput\(admin, rawOutputId/);

assert.match(worker, /original_preserved: true/);
assert.match(worker, /ai_called: false/);
assert.match(providerAdapter, /rawResponseBody/);
assert.match(providerAdapter, /rawOutputText/);
assert.match(providerAdapter, /finishReason/);
assert.match(rawOutputRepairMigration, /CREATE TABLE IF NOT EXISTS public\.encounter_schedule_generation_outputs/);
assert.match(rawOutputRepairMigration, /CREATE TABLE IF NOT EXISTS public\.encounter_schedule_generation_output_revisions/);
assert.match(rawOutputRepairMigration, /ENABLE ROW LEVEL SECURITY/);
assert.match(rawOutputRepairMigration, /REVOKE ALL ON TABLE public\.encounter_schedule_generation_outputs FROM PUBLIC, anon, authenticated/);
assert.match(rawOutputRepairMigration, /claim_encounter_schedule_repair/);
assert.match(rawOutputRepairMigration, /p_expected_source_hash/);
assert.match(rawOutputRepairMigration, /expires_at timestamptz NOT NULL DEFAULT/);
assert.match(rawOutputRepairMigration, /encounter_schedule_raw_output_immutable/);
assert.match(rawOutputRepairMigration, /encounter_schedule_output_revision_immutable/);
assert.match(rawOutputRepairMigration, /encounter_schedule_original_ai_response_is_immutable/);
assert.match(rawOutputRepairMigration, /encounter_schedule_manual_revision_is_immutable/);
assert.match(rawOutputRepairReplay, /encounter_schedule_private_ai_output_exposed_to_client_roles/);
assert.match(rawOutputRepairReplay, /encounter_schedule_repair_rpc_grants_invalid/);
assert.match(rawOutputRepairReplay, /encounter_schedule_immutable_triggers_missing/);


assert.doesNotMatch(worker, /get_encounter_dynamic_scene_usage|dynamic_scene_limit_or_sharing_invalid/);
assert.match(worker, /findPrivateContextLeak/);
assert.match(worker, /\.eq\("status", "pending"\)/);
assert.match(worker, /failed_jobs_preserved: true/);
assert.match(worker, /status: "no_pending_jobs"/);
assert.doesNotMatch(worker, /enqueue_encounter_schedule_generation_test_batch/,
  "Manual test clicks must not rescan or re-enqueue failed characters");
assert.match(worker, /p_force: mode === "manual"/);
assert.match(worker, /const sceneCatalog = sceneCatalogError[\s\S]*?\? \[\][\s\S]*?EncounterSceneCatalogEntry/);
assert.match(worker, /Scene metadata is only an optional exact-name hint/);
assert.doesNotMatch(worker, /scene_catalog_unavailable/);
const manualRetryGuard = worker.slice(
  worker.indexOf("// Manual testing never retries terminal failures."),
  worker.indexOf("const { data: claimData", worker.indexOf("// Manual testing never retries terminal failures.")),
);
assert.match(manualRetryGuard, /\.eq\("status", "processing"\)/);
assert.match(manualRetryGuard, /\.eq\("status", "needs_reconciliation"\)/);
assert.match(manualRetryGuard, /\.eq\("status", "pending"\)/);
assert.match(html, /const canRun=pending>0&&!blocked/);
assert.match(html, /失敗紀錄已保留，不會自動重試/);
assert.match(worker, /ENCOUNTER_SCHEDULE_TEST_MODE/);
assert.doesNotMatch(worker, /ENCOUNTER_SCHEDULE_TEST_USER_IDS/);
assert.doesNotMatch(worker, /account_is_active/);
assert.match(worker, /auth\.getUser\(\)/);
assert.match(worker, /test_mode: true/);
assert.match(worker, /mode === "status"/);
assert.match(worker, /status_available/);
assert.match(worker, /scheduled_trigger_requires_service_role/);
assert.match(worker, /provider_request_outcome_unknown|schedule_provider_outcome_unknown/);
assert.doesNotMatch(worker, /reserve_chat_turn|settle_chat_turn/,
  "Schedule generation must not charge a user wallet");
assert.ok(
  worker.indexOf('if (!openRouterKey)') < worker.indexOf('claim_encounter_schedule_batch'),
  "Missing provider secret must not claim or lock schedule jobs",
);
assert.ok(
  worker.indexOf('if (Deno.env.get("ENCOUNTER_SCHEDULE_TEST_MODE") !== "true"') <
    worker.indexOf('p_force: mode === "manual"'),
  "Manual force path must remain test-environment gated",
);

assert.match(pipeline, /CREATE TRIGGER character_schedule_descriptions_enqueue_ai[\s\S]*?AFTER INSERT OR UPDATE OF description, author_id OR DELETE/);
assert.match(pipeline, /CREATE TRIGGER characters_enqueue_encounter_schedule_ai[\s\S]*?AFTER INSERT OR UPDATE OF author_id, name, title, intro, race, style, gender, age, tags,[\s\S]*?personality_profile, visibility, review_status, rights_confirmed, deleted_at/);
assert.match(pipeline, /CREATE TRIGGER character_private_info_enqueue_encounter_schedule_ai[\s\S]*?AFTER INSERT OR UPDATE OF author_id, private_info OR DELETE/);
assert.match(pipeline, /'existing_author_schedules', COALESCE\(\([\s\S]*?source_type = 'manual'/);
assert.match(pipeline, /PERFORM public\.enqueue_encounter_schedule_generation_internal\(p_character_id\)/);
assert.match(pipeline, /LEFT JOIN public\.character_schedule_descriptions d/);
assert.doesNotMatch(pipeline, /btrim\(COALESCE\(d\.description, ''\)\) <> ''/,
  "AI schedule generation must support public characters with no author-entered schedule");
assert.match(pipeline, /enqueue_encounter_schedule_generation_internal/);
assert.match(batchSemantics, /v_oldest > v_now - interval '24 hours'/);
assert.ok(batchSemantics.includes("MAX(b.completed_at)"));
assert.ok(!worker.includes("sources.length > 10"));
assert.match(batchSemantics, /v_last_completed > v_now - interval '6 hours'/);
assert.doesNotMatch(batchSemantics, /v_daily_count|daily_limit|four batches per/i);
assert.match(batchSemantics, /schedule_batch_character_count_invalid/);
assert.match(batchSemantics, /remaining_character_count/);
assert.match(worker, /p_characters: \[item\.character\]/);
assert.match(pipeline, /WHEN public\.encounter_schedule_generation_jobs\.status IN[\s\S]*?'pending', 'processing', 'failed', 'needs_reconciliation'[\s\S]*?THEN public\.encounter_schedule_generation_jobs\.queued_at/);
assert.match(pipeline, /CREATE TABLE IF NOT EXISTS public\.encounter_city_weather/);
assert.doesNotMatch(pipeline, /encounter_weather_baseline_2025/, "Illustrative weather must not depend on historical weather imports");
assert.match(pipeline, /CREATE OR REPLACE FUNCTION public\.get_encounter_city_weather\(\)/);
assert.match(pipeline, /CREATE OR REPLACE FUNCTION public\.schedule_encounter_weather_sync\(/);
assert.match(pipeline, /'0 \*\/6 \* \* \*'/);
assert.match(pipeline, /FROM public\.get_encounter_city_weather\(\) AS weather/);
assert.match(pipeline, /CREATE TABLE IF NOT EXISTS public\.encounter_scene_registry/);
assert.match(pipeline, /location_key IN \('shopping-street'\)/);
assert.match(pipeline, /minimum_character_count smallint NOT NULL DEFAULT 1/);
assert.match(pipeline, /CREATE OR REPLACE FUNCTION public\.get_encounter_scene_registry\(\)/);
assert.match(pipeline, /ADD COLUMN IF NOT EXISTS special_event_key text/);
assert.match(pipeline, /CREATE OR REPLACE FUNCTION public\.resolve_encounter_special_event_key/);
assert.match(pipeline, /special_event_key IS NULL/);
assert.match(generator, /special_events/);
assert.match(generator, /valentines_day/);
assert.match(generator, /lunar_new_year/);
assert.match(generator, /christmas/);
assert.match(generator, /角色生日目前沒有結構化日期來源/);
assert.match(pipeline, /CREATE OR REPLACE FUNCTION public\.get_encounter_character_schedules\(p_character_ids uuid\[\]\)[\s\S]*?CROSS JOIN LATERAL public\.resolve_encounter_character_schedule/);
assert.match(pipeline, /encounter_greeting text,[\s\S]*?is_outdoor boolean,[\s\S]*?rain_fallback_greeting text,[\s\S]*?variant_weight smallint/);
assert.match(pipeline, /cardinality\(p_character_ids\) BETWEEN 1 AND 10/);
assert.match(pipeline, /count\(DISTINCT c\.id\)/);
assert.match(pipeline, /HAVING pg_catalog\.count\(DISTINCT c\.id\) >= r\.minimum_character_count/);
assert.match(pipeline, /ORDER BY r\.display_order, r\.location_key\s+LIMIT 3/);
assert.match(fs.readFileSync("city-map.js", "utf8"), /MAX_DYNAMIC_SCENE_MARKERS=3/);
assert.match(fs.readFileSync("city-map.js", "utf8"), /Math\.hypot\(point\.x-x,point\.y-y\)<120/);
assert.match(pipeline, /marker_x BETWEEN 40 AND 1622/);
assert.match(pipeline, /marker_y BETWEEN 40 AND 892/);
assert.match(generator, /地點是否能對應地圖由系統自行判斷/);
assert.match(generator, /scene_description/);
assert.match(generator, /location（自然語言地點名稱）/);
assert.doesNotMatch(generator, /canonical_scene_keys/);
assert.doesNotMatch(generator, /scene_catalog/);
assert.match(generator, /行程以角色自身日常活動為準/);
assert.match(generator, /ENCOUNTER_SCHEDULE_MAX_HOURLY_BLOCKS_PER_DAY = 24/);
assert.match(generator, /0–24 個逐小時時段/);
assert.match(generator, /不同時段獨立抽取/);
assert.match(generator, /同一時段所有選項權重總和必須恰好 100/);
assert.match(hourlyScheduleMigration, /character_schedules_ai_hourly_option_unique_idx/);
assert.match(hourlyScheduleMigration, /schedule_hourly_option_weights_must_sum_100/);
assert.match(hourlyScheduleMigration, /v_option_roll/);
assert.match(hourlyScheduleMigration, /hourly-options-v1/);
assert.match(hourlyScheduleMigration, /option_1/);
assert.match(hourlyScheduleMigration, /poyozz-encounter-schedule-v6-hourly-independent-options-2026-11-18/);
assert.ok(pendingPriorityMigration.includes("ORDER BY CASE j.status WHEN ''pending'' THEN 0 WHEN ''failed'' THEN 1 ELSE 2 END"));
assert.ok(pendingPriorityMigration.includes("pending_schedule_job_priority_contract_count_unexpected"));
assert.ok(replayWorkflow.includes("20261118074723_prioritize_pending_encounter_schedule_jobs.sql"));
assert.ok(replayWorkflow.includes("20261118074727_encounter_schedule_raw_output_repair.sql"));
assert.ok(replayWorkflow.indexOf("20261118074727_encounter_schedule_raw_output_repair.sql") >
  replayWorkflow.indexOf("20261118074723_prioritize_pending_encounter_schedule_jobs.sql"));
assert.ok(replayWorkflow.lastIndexOf("replay-encounter-schedule-output-repair.sql") >
  replayWorkflow.indexOf("20261118074727_encounter_schedule_raw_output_repair.sql"));


assert.match(generator, /scenes 必須是空陣列/);
assert.doesNotMatch(generator, /本批次只有 1 位角色使用也可以提出候選/);
assert.doesNotMatch(generator, /shoppingStreetUsers/);
assert.match(pipeline, /schedule_variant_24_hour_coverage_incomplete/);
assert.match(pipeline, /jsonb_array_length\(v_variant->'slots'\) NOT BETWEEN 2 AND 4/);
assert.doesNotMatch(generator, /_24_hour_coverage_incomplete/);
assert.doesNotMatch(generator, /完整 24 小時行程/);
assert.match(sparseScheduleMigration, /NOT BETWEEN 0 AND 4/);
assert.match(sparseScheduleMigration, /NOT BETWEEN 1 AND 4/);
assert.match(sparseScheduleMigration, /daily_canonical_scene_key_contract_count_unexpected/);
assert.match(sparseScheduleMigration, /special_event_canonical_scene_key_contract_count_unexpected/);
assert.doesNotMatch(generator, /scene_not_in_existing_catalog/);
assert.match(publishedSceneResolverMigration, /public\.get_encounter_scene_catalog\(\)/);
assert.match(sceneDescriptionMigration, /location_description text NOT NULL DEFAULT ''/);
assert.match(sceneDescriptionMigration, /scene_description text NOT NULL DEFAULT ''/);
assert.match(sceneDescriptionMigration, /resolve_encounter_scene_location_key/);
assert.match(sceneDescriptionMigration, /publish_encounter_scene_metadata/);
assert.match(sceneDescriptionMigration, /get_encounter_character_schedules_with_scene/);
assert.match(sceneDescriptionMigration, /poyozz-encounter-schedule-v5-natural-locations-scene-descriptions-2026-11-18/);
assert.match(fs.readFileSync("index.html", "utf8"), /get_encounter_character_schedules_with_scene/);
assert.match(fs.readFileSync("city-map.js", "utf8"), /citySceneDescription/);
assert.match(weatherWorker, /createEncounterWeather/);
assert.match(weatherWorker, /previousSlot === weather\.slot/);
assert.match(weatherWorker, /previous\.source === weather\.source/);
assert.match(weatherWorker, /previous\?\.source === weather\.source/);
assert.match(weatherWorker, /encounter_city_weather/);
assert.doesNotMatch(weatherWorker, /O-A0001-001|O-A0002-001|CWA_OPEN_DATA_API_KEY|fetch\(/);
assert.doesNotMatch(weatherWorker, /reserve_chat_turn|settle_chat_turn/);
assert.match(weatherParser, /Asia\/Taipei/);
assert.match(weatherParser, /poyozz_fictional_seasonal/);
assert.match(weatherParser, /isRainWeatherText/);
assert.doesNotMatch(weatherParser, /Past1hr|CWA_OPEN_DATA_API_KEY/);
assert.doesNotMatch(pipeline, /SELECT public\.schedule_encounter_schedule_organizer\(true\)/,
  "Migration draft must not activate the hosted cron job automatically");

assert.match(html, /id="encounterScheduleTestTools"/);
assert.match(html, /functions\.invoke\('encounter-schedule-organizer',\{body:\{mode:'status'\}\}\)/);
assert.match(html, /functions\.invoke\('encounter-schedule-organizer',\{body:\{mode:'manual'\}\}\)/);
assert.match(html, /loadEncounterScheduleRepairOutputs/);
assert.match(html, /mode:'repair_list'/);
assert.match(html, /mode:'repair'/);
assert.match(html, /repair-encounter-schedule-output/);
assert.match(html, /不會再次呼叫 AI/);

assert.match(html, /case 'environment':[\s\S]*?void loadEncounterScheduleTestTools\(\)/);
assert.doesNotMatch(html, /kind==='album'&&CHAT_DATA_TEST_MODE/);

console.log("Encounter schedule worker, conditional holidays, existing-scene-only rules, sparse encounter windows, simulated Taipei weather, queue triggers, and throttling contracts passed.");
