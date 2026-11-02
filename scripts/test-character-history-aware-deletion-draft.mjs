import fs from "node:fs";
import assert from "node:assert/strict";

const sql = fs.readFileSync("supabase/drafts/character-history-aware-deletion.sql", "utf8");
const worker = fs.readFileSync("supabase/functions/_shared/character-asset-cleanup-worker.ts", "utf8");
const edge = fs.readFileSync("supabase/functions/purge-character-assets/index.ts", "utf8");

assert.match(sql, /CREATE OR REPLACE FUNCTION private\.lock_character_asset_path\(/);
assert.match(sql, /pg_advisory_xact_lock\([\s\S]*hashtextextended\(p_bucket_id\s*\|\|\s*':'\s*\|\|\s*p_object_path/);
assert.match(sql, /CREATE TRIGGER prevent_reuse_queued_character_avatar_video[\s\S]*ON public\.characters[\s\S]*EXECUTE FUNCTION private\.prevent_reuse_queued_character_asset\(\)/);
assert.match(sql, /CREATE TRIGGER prevent_reuse_queued_character_illustration[\s\S]*ON public\.character_illustrations[\s\S]*EXECUTE FUNCTION private\.prevent_reuse_queued_character_asset\(\)/);
assert.match(sql, /character_asset_path_cleanup_already_queued/);
assert.match(sql, /ORDER BY 1, 2[\s\S]*LOOP[\s\S]*private\.lock_character_asset_path\(v_asset\.bucket_id, v_asset\.object_path\)/);
assert.match(sql, /ci\.storage_path IS NULL[\s\S]*ci\.storage_path !~/);

// Only an actual INSERT creates the immutable private-draft origin record.
// This avoids BEFORE INSERT upsert triggers marking an existing legacy row.
assert.match(sql, /CREATE TABLE IF NOT EXISTS private\.character_private_draft_origins/);
assert.match(sql, /AFTER INSERT ON public\.characters[\s\S]*EXECUTE FUNCTION private\.record_character_private_draft_origin\(\)/);\nassert.doesNotMatch(sql, /BEFORE INSERT ON public\.characters[\s\S]*record_character_private_draft_origin/);
assert.match(sql, /REVOKE ALL ON private\.character_private_draft_origins FROM PUBLIC, anon, authenticated, service_role/);
assert.match(sql, /UPDATE public\.characters[\s\S]*WHERE visibility = 'public'[\s\S]*first_published_at IS NULL/);
assert.match(sql, /OLD\.visibility = 'public' OR NEW\.visibility = 'public'[\s\S]*NEW\.first_published_at := pg_catalog\.statement_timestamp\(\)/);
assert.match(sql, /v_private_draft_origin[\s\S]*v_visibility = 'private'[\s\S]*v_review_status = 'draft'/);
assert.match(sql, /private\.character_private_draft_origins d WHERE d\.character_id = c\.id/);


const deleteStart = sql.indexOf("CREATE OR REPLACE FUNCTION public.soft_delete_character(");
const claimStart = sql.indexOf("CREATE OR REPLACE FUNCTION public.claim_character_asset_cleanup_jobs(", deleteStart);
assert.ok(deleteStart >= 0 && claimStart > deleteStart);
const deleteFn = sql.slice(deleteStart, claimStart);
assert.match(deleteFn, /private\.lock_character_asset_path\(/);
assert.match(deleteFn, /INSERT INTO public\.character_asset_cleanup_jobs/);

assert.match(worker, /await deps\.isReferenced\(job\.bucket_id, job\.object_path\)/);
assert.match(worker, /if \(reference\.referenced\)/);
assert.match(worker, /await deps\.removeObject\(job\.bucket_id, job\.object_path\)/);
assert.ok(
  worker.indexOf("await deps.isReferenced(job.bucket_id, job.object_path)") <
    worker.indexOf("await deps.removeObject(job.bucket_id, job.object_path)"),
  "Storage removal must happen only after a successful reference check",
);
assert.match(edge, /character-avatar-videos/);
assert.match(edge, /character-illustrations/);

const historyStart = sql.indexOf("CREATE OR REPLACE FUNCTION private.character_has_history(");
const publicationStart = sql.indexOf("CREATE OR REPLACE FUNCTION private.preserve_character_first_publication_timestamp(", historyStart);
assert.ok(historyStart >= 0 && publicationStart > historyStart);
const historyFn = sql.slice(historyStart, publicationStart);
// Every current FK-backed player-history source must block the never-published
// hard-delete path. Names come from the accompanying read-only live catalog inventory.
for (const table of [
  "chat_sessions", "chat_group_members", "chat_group_messages", "chat_groups",
  "conversations", "encounter_character_state", "encounter_diary",
  "encounter_turn_interaction_receipts", "encounter_session_lifecycle",
  "encounter_session_turns", "encounter_session_evaluation_jobs",
  "story_relationship_batches", "story_relationship_states", "character_comments",
  "chat_deletion_character_history",
]) {
  assert.ok(historyFn.includes(`FROM public.${table}`), `Character history guard must include ${table}`);
}
// Creator-authored draft metadata may cascade with a never-used draft. Story templates
// are separately protected when a legacy conversation references them.
for (const table of [
  "character_private_info", "character_schedule_descriptions",
  "character_schedules", "character_illustrations",
]) {
  assert.ok(!historyFn.includes(`FROM public.${table}`), `Do not classify draft metadata ${table} as player history`);
}
assert.match(historyFn, /JOIN public\.character_stories cs ON cs\.id = cv\.story_id/,
  "Legacy conversations must preserve the linked character story");


console.log("Character asset cleanup path-lock and reference guards passed.");
