import assert from "node:assert/strict";
import fs from "node:fs";

const worker = fs.readFileSync("supabase/functions/encounter-schedule-organizer/index.ts", "utf8");
const pipeline = fs.readFileSync("supabase/drafts/encounter-schedule-pipeline.sql", "utf8");
const html = fs.readFileSync("index.html", "utf8");
const generator = fs.readFileSync("supabase/functions/_shared/encounter-schedule-generation.ts", "utf8");

assert.match(worker, /requestOpenRouterChatCompletion/);
assert.match(worker, /POYOZZ_DEFAULT_CHAT_MODEL/);
assert.match(worker, /claim_encounter_schedule_batch/);
assert.match(worker, /publish_encounter_schedule_batch/);
assert.match(worker, /fail_encounter_schedule_batch/);
assert.match(worker, /parseEncounterScheduleBatchOutput/);
assert.match(worker, /findPrivateContextLeak/);
assert.match(worker, /p_limit: 10/);
assert.match(worker, /p_force: mode === "manual"/);
assert.match(worker, /ENCOUNTER_SCHEDULE_TEST_MODE/);
assert.match(worker, /ENCOUNTER_SCHEDULE_TEST_USER_IDS/);
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
assert.match(pipeline, /CREATE TRIGGER characters_enqueue_encounter_schedule_ai[\s\S]*?AFTER UPDATE OF visibility, review_status, rights_confirmed, deleted_at/);
assert.match(pipeline, /enqueue_encounter_schedule_generation_internal/);
assert.match(pipeline, /WHEN public\.encounter_schedule_generation_jobs\.status IN[\s\S]*?'pending', 'processing', 'failed', 'needs_reconciliation'[\s\S]*?THEN public\.encounter_schedule_generation_jobs\.queued_at/);
assert.match(pipeline, /v_oldest > v_now - interval '23 hours 45 minutes'/);
assert.match(pipeline, /v_daily_count >= 4/);
assert.match(pipeline, /v_last_started > v_now - interval '6 hours'/);
assert.match(pipeline, /CREATE TABLE IF NOT EXISTS public\.encounter_scene_registry/);
assert.match(pipeline, /location_key IN \('shopping-street'\)/);
assert.match(pipeline, /minimum_character_count smallint NOT NULL DEFAULT 1/);
assert.match(pipeline, /CREATE OR REPLACE FUNCTION public\.get_encounter_scene_registry\(\)/);
assert.match(pipeline, /count\(DISTINCT c\.id\)/);
assert.match(pipeline, /HAVING pg_catalog\.count\(DISTINCT c\.id\) >= r\.minimum_character_count/);
assert.match(pipeline, /marker_x BETWEEN 40 AND 1622/);
assert.match(pipeline, /marker_y BETWEEN 40 AND 892/);
assert.match(generator, /Preserve a candidate scene even when only one character is in this AI batch/);
assert.doesNotMatch(generator, /shoppingStreetUsers/);
assert.match(pipeline, /schedule_variant_24_hour_coverage_incomplete/);
assert.match(pipeline, /jsonb_array_length\(v_variant->'slots'\) NOT BETWEEN 2 AND 4/);
assert.match(generator, /_24_hour_coverage_incomplete/);
assert.match(generator, /完整 24 小時行程/);
assert.doesNotMatch(pipeline, /SELECT public\.schedule_encounter_schedule_organizer\(true\)/,
  "Migration draft must not activate the hosted cron job automatically");

assert.match(html, /id="encounterScheduleTestTools"/);
assert.match(html, /functions\.invoke\('encounter-schedule-organizer',\{body:\{mode:'status'\}\}\)/);
assert.match(html, /functions\.invoke\('encounter-schedule-organizer',\{body:\{mode:'manual'\}\}\)/);
assert.match(html, /if\(kind==='album'&&CHAT_DATA_TEST_MODE\)void loadEncounterScheduleTestTools\(\)/);

console.log("Encounter schedule worker, queue triggers, throttling, and 24-hour coverage contracts passed.");
