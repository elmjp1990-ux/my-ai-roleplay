import assert from "node:assert/strict";
import fs from "node:fs";

const worker = fs.readFileSync("supabase/functions/encounter-schedule-organizer/index.ts", "utf8");
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

console.log("Encounter schedule worker security and no-wallet-charge contracts passed.");
