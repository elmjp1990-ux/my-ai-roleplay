import assert from "node:assert/strict";
import fs from "node:fs";
import { parseEncounterSessionEvaluation } from "../supabase/functions/_shared/encounter-session-evaluation.mjs";

const valid = {
  affinity_delta: 6,
  relationship_stage: "acquaintance",
  memories: ["玩家喜歡在雨天去咖啡廳。"],
  diary_summary: "兩人一起在咖啡廳避雨，聊了彼此近期的生活。",
  rationale: "玩家主動分享近況，角色也有回應與互相理解。",
};
assert.deepEqual(parseEncounterSessionEvaluation(JSON.stringify(valid)), {
  affinityDelta: 6,
  relationshipStage: "acquaintance",
  memories: ["玩家喜歡在雨天去咖啡廳。"],
  diarySummary: valid.diary_summary,
  rationale: valid.rationale,
});

for (const stage of [
  "hostile", "dislike", "wary", "first_meeting",
  "acquaintance", "close", "intimate", "special",
]) {
  assert.equal(parseEncounterSessionEvaluation({ ...valid, relationship_stage: stage }).relationshipStage, stage);
}
assert.equal(parseEncounterSessionEvaluation("{not-json"), null);
assert.equal(parseEncounterSessionEvaluation([]), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, affinity_delta: 101 }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, affinity_delta: -101 }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, affinity_delta: 1.5 }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, relationship_stage: "unknown" }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, memories: Array(6).fill("記憶") }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, memories: [""] }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, memories: ["x".repeat(501)] }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, diary_summary: "" }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, rationale: "" }), null);

const worker = fs.readFileSync("supabase/functions/encounter-evaluation-worker/index.ts", "utf8");
assert.match(worker, /Authorization.*Bearer.*serviceRoleKey/);
assert.match(worker, /claim_encounter_evaluation_jobs/);
assert.match(worker, /settle_encounter_session/);
assert.match(worker, /fail_encounter_evaluation_job/);
assert.match(worker, /encounter_session_turns/);
assert.match(worker, /POYOZZ_DEFAULT_CHAT_MODEL/);
assert.match(worker, /MAX_TRANSCRIPT_CHARS/);
assert.match(worker, /scheduled_end_at/);
assert.match(worker, /encounter_session_turns/);
assert.match(worker, /chat_messages/);
assert.doesNotMatch(worker, /reserve_chat_turn|settle_chat_turn|refund_chat_turn/,
  "Scene evaluation must never touch the player wallet");

const config = fs.readFileSync("supabase/config.toml", "utf8");
assert.match(config, /\[functions\.encounter-evaluation-worker\][\s\S]*?verify_jwt = false/);

const scheduleDraft = fs.readFileSync("supabase/drafts/schedule-encounter-evaluation-worker.sql", "utf8");
assert.match(scheduleDraft, /schedule_encounter_evaluation_worker\(p_enabled boolean DEFAULT false\)/);
assert.match(scheduleDraft, /IF p_enabled IS NOT TRUE/);
assert.match(scheduleDraft, /vault\.decrypted_secrets/);
assert.match(scheduleDraft, /encounter-evaluation-worker/);
assert.doesNotMatch(scheduleDraft, /DO \$[^$]+\$[\s\S]*?schedule\(/,
  "Worker cron must remain opt-in and must not be activated by applying the draft");

console.log("Encounter session evaluator parser, lifecycle gates, wallet isolation, and opt-in worker schedule contracts passed.");
