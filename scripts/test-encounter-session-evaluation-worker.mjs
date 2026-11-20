import assert from "node:assert/strict";
import fs from "node:fs";
import { parseEncounterSessionEvaluation } from "../supabase/functions/_shared/encounter-session-evaluation.mjs";

const valid = {
  memories: ["玩家喜歡在雨天去咖啡廳。"],
  diary_summary: "兩人一起在咖啡廳避雨，聊了彼此近期的生活。",
  rationale: "玩家主動分享近況，角色也有回應與互相理解。",
};
assert.deepEqual(parseEncounterSessionEvaluation(JSON.stringify(valid)), {
  memories: ["玩家喜歡在雨天去咖啡廳。"],
  diarySummary: valid.diary_summary,
  rationale: valid.rationale,
});

assert.equal(parseEncounterSessionEvaluation("{not-json"), null);
assert.equal(parseEncounterSessionEvaluation([]), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, memories: Array(6).fill("記憶") }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, memories: [""] }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, memories: ["x".repeat(501)] }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, diary_summary: "" }), null);
assert.equal(parseEncounterSessionEvaluation({ ...valid, rationale: "" }), null);

const worker = fs.readFileSync("supabase/functions/encounter-evaluation-worker/index.ts", "utf8");
assert.match(worker, /ENCOUNTER_DISCOVERY_SENTINEL/);
assert.match(worker, /玩家選擇留空，讓角色主動發現自己/);
assert.match(worker, /玩家留空發送，請角色自然延續目前互動/);
assert.match(worker, /Authorization.*Bearer.*serviceRoleKey/);
assert.match(worker, /claim_encounter_evaluation_jobs/);
assert.match(worker, /requestedSessionId/);
assert.match(worker, /claim_encounter_evaluation_job/);
assert.match(worker, /UUID_PATTERN/);
assert.match(worker, /settle_encounter_session/);
assert.match(worker, /persistEncounterSummary/);
assert.match(worker, /encounterSummary: summary\.slice\(0, 1200\)/);
assert.match(worker, /encounterEndedAt: Date\.parse\(endedAt\)/);
assert.match(worker, /lifecycle\.status === "settled"[\s\S]*?summarySynced/,
  "A retry after affinity settlement must sync the saved summary without re-running evaluation");
assert.match(worker, /fail_encounter_evaluation_job/);
assert.match(worker, /encounter_session_turns/);
assert.match(worker, /POYOZZ_DEFAULT_CHAT_MODEL/);
assert.match(worker, /MAX_TRANSCRIPT_CHARS/);
assert.match(worker, /scheduled_end_at/);
assert.match(worker, /encounter_session_turns/);
assert.match(worker, /chat_messages/);
assert.ok(
  worker.indexOf('if (Number(job.turn_count) === 0)') < worker.indexOf('if (!apiKey)'),
  "Zero-turn scenes must settle neutrally without requiring an AI provider key",
);
assert.doesNotMatch(worker, /if \(!openRouterKey\) return json\(\{ error: "ai_provider_not_configured"/,
  "Missing provider credentials must not block neutral no-turn settlement");
assert.doesNotMatch(worker, /reserve_chat_turn|settle_chat_turn|refund_chat_turn/,
  "Scene evaluation must never touch the player wallet");

const config = fs.readFileSync("supabase/config.toml", "utf8");
assert.match(config, /\[functions\.encounter-evaluation-worker\][\s\S]*?verify_jwt = false/);

const scheduleDraft = fs.readFileSync("supabase/drafts/schedule-encounter-evaluation-worker.sql", "utf8");
const manualEndDraft = fs.readFileSync("supabase/drafts/encounter-session-manual-end.sql", "utf8");
const evidenceGates = fs.readFileSync("supabase/drafts/encounter-evaluation-evidence-gates.sql", "utf8");
const sessionStateEdge = fs.readFileSync("supabase/functions/encounter-session-state/index.ts", "utf8");
const frontend = fs.readFileSync("index.html", "utf8");
assert.match(scheduleDraft, /schedule_encounter_evaluation_worker\([\s\S]*?p_enabled boolean DEFAULT false/);
assert.match(scheduleDraft, /IF p_enabled IS NOT TRUE/);
assert.match(scheduleDraft, /vault\.decrypted_secrets/);
assert.match(scheduleDraft, /encounter-evaluation-worker/);
assert.match(scheduleDraft, /COALESCE\(auth\.role\(\), ''\) <> 'service_role'/,
  "Only an authenticated service-role caller may configure the scheduler");
const command = scheduleDraft.match(/v_command := \$command\$([\s\S]*?)\$command\$;/)?.[1] ?? "";
assert.match(command, /PERFORM public\.enqueue_due_encounter_evaluations\(50\)/,
  "Cron must enqueue expired scenes before dispatching the worker");
assert.match(command, /PERFORM net\.http_post/);
assert.doesNotMatch(command, /cron\.schedule/,
  "The recurring cron command must not create or reconfigure cron jobs");
assert.match(scheduleDraft, /IF p_enabled IS NOT TRUE[\s\S]*?RETURN 'disabled'/);
assert.match(scheduleDraft, /PERFORM cron\.schedule\(/,
  "Only the explicit enabled path may register the recurring cron job");
assert.match(evidenceGates, /charge\.status IN \('created','reserved','needs_reconciliation'\)/);
assert.match(evidenceGates, /charge\.status='settled'[\s\S]*?NOT EXISTS \([\s\S]*?encounter_session_turns/);
assert.match(evidenceGates, /count\(\*\)[\s\S]*?<> l\.turn_count/);
assert.match(evidenceGates, /settlement_result=v_result/);
assert.match(manualEndDraft, /p_action NOT IN \('pause','resume','end'\)/);
assert.match(manualEndDraft, /status='ready_to_settle'[\s\S]*?scheduled_end_at=v_effective_end/);
assert.match(manualEndDraft, /schedule_snapshot/);
assert.match(sessionStateEdge, /\["pause", "resume", "end"\]/);
assert.match(frontend, /setEncounterLifecycleState\(session\.id,'end'\)/,
  "The explicit end action must request server-side settlement rather than only archiving the local chat");

const specificClaimMigration = fs.readFileSync(
  "supabase/migrations/20261120010100_claim_encounter_evaluation_job_by_session.sql",
  "utf8",
);
assert.match(specificClaimMigration, /FUNCTION public\.claim_encounter_evaluation_job\(p_session_id uuid\)/);
assert.match(specificClaimMigration, /WHERE job\.session_id=p_session_id/);
assert.match(specificClaimMigration, /FOR UPDATE OF job,lifecycle SKIP LOCKED/);
assert.match(specificClaimMigration, /job\.attempt_count < 5/);
assert.match(specificClaimMigration, /lifecycle\.status='ready_to_settle'/);
assert.match(specificClaimMigration, /chat_turn_charges/);
assert.match(specificClaimMigration, /encounter_session_turns/);
assert.match(specificClaimMigration, /GRANT EXECUTE ON FUNCTION public\.claim_encounter_evaluation_job\(uuid\) TO service_role/);
assert.match(sessionStateEdge, /encounter_session_evaluation_jobs/);
assert.match(sessionStateEdge, /action === "pause" \|\| action === "resume"/);
assert.match(sessionStateEdge, /encounterTemporarilyLeftAt: Date\.now\(\)/);
assert.match(sessionStateEdge, /encounterTemporarilyLeftAt: null/);
assert.match(sessionStateEdge, /encounter_state_metadata_persistence_failed/);
assert.match(sessionStateEdge, /EdgeRuntime/);
assert.match(sessionStateEdge, /sessionId: lifecycle\.session_id/);
assert.match(sessionStateEdge, /encounter-evaluation-worker/);
assert.match(sessionStateEdge, /session_data: \{ \.\.\.currentSessionData, archived: true, encounterEndedAt: Date\.now\(\) \}/, "Manual end must mark the session finished immediately, even if AI summary evaluation fails");
assert.doesNotMatch(sessionStateEdge, /enqueue_due_encounter_evaluations/,
  "A manual end must not enqueue or drain unrelated users' due sessions");

assert.doesNotMatch(worker, /affinity_delta.*整場相遇|relationship_stage.*八種階段/);
console.log("Encounter session evaluator summary/memory parser, lifecycle gates, manual end, wallet isolation, and opt-in worker schedule contracts passed.");
