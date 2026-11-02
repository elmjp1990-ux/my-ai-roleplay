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

console.log("Character asset cleanup path-lock and reference guards passed.");
