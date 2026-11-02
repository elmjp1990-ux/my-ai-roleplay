import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const draftPath = "supabase/drafts/account-deletion-character-preservation-draft.sql";
const sql = fs.readFileSync(draftPath, "utf8");

assert.match(sql, /^-- DRAFT ONLY — NOT AN ACTIVE MIGRATION\./);
assert.match(sql, /Do not execute this file against the hosted Supabase project/);

for (const table of ["characters", "character_private_info", "character_illustrations", "character_schedule_descriptions"]) {
  assert.match(sql, new RegExp("ALTER TABLE public[.]" + table + "[\\s\\S]*?ALTER COLUMN author_id DROP NOT NULL"));
  assert.match(sql, new RegExp("ALTER TABLE public[.]" + table + "[\\s\\S]*?ON DELETE SET NULL"));
}
assert.match(sql, /character_schedule_descriptions[\s\S]*?REFERENCES auth[.]users[(]id[)] ON DELETE SET NULL/);
assert.match(sql, /creator_display_name/);
assert.match(sql, /creator_handle_snapshot/);
assert.match(sql, /account_archived_at timestamptz/);

const existingSessionFn = sql.match(/CREATE OR REPLACE FUNCTION private[.]user_has_existing_character_session[(][\s\S]*?\$function\$;/)?.[0];
assert.ok(existingSessionFn, "existing-session helper must exist");
assert.match(existingSessionFn, /SET search_path TO ''/);
assert.match(existingSessionFn, /auth[.]uid[(][)]/);
assert.match(existingSessionFn, /s[.]user_id = auth[.]uid[(][)]/);
assert.match(existingSessionFn, /g[.]owner_id = auth[.]uid[(][)]/);
assert.match(existingSessionFn, /g[.]deleted_at IS NULL/);
assert.doesNotMatch(existingSessionFn, /g[.]archived_at IS NULL/);
assert.match(existingSessionFn, /s[.]deleted_at IS NULL/);

const assetFn = sql.match(/CREATE OR REPLACE FUNCTION private[.]can_read_character_asset[(][\s\S]*?\$function\$;/)?.[0];
assert.ok(assetFn, "exact-path media helper must exist");
assert.match(assetFn, /SET search_path TO ''/);
assert.match(assetFn, /ci[.]storage_path = p_object_name/);
assert.match(assetFn, /c[.]avatar_video_path = p_object_name/);
assert.match(assetFn, /ELSE false/);
assert.match(sql, /CREATE POLICY "Existing session owners can read archived character assets"[\s\S]*?FOR SELECT TO authenticated/);
assert.match(sql, /CREATE POLICY "Existing session owners can read character illustration metadata"[\s\S]*?FOR SELECT TO authenticated/);

const archiveFn = sql.match(/CREATE OR REPLACE FUNCTION private[.]archive_account_characters[(][\s\S]*?\$function\$;/)?.[0];
assert.ok(archiveFn, "account archive helper must exist");
assert.match(archiveFn, /auth[.]jwt[(][)] ->> 'role'/);
assert.match(archiveFn, /IS DISTINCT FROM 'service_role'/);
assert.match(archiveFn, /SECURITY DEFINER/);
assert.match(archiveFn, /SET search_path TO ''/);
for (const table of ["chat_sessions", "chat_group_members", "chat_group_messages", "character_private_info", "character_illustrations", "character_schedule_descriptions", "characters"]) {
  assert.match(archiveFn, new RegExp("UPDATE public[.]" + table));
}
assert.match(archiveFn, /visibility = 'private'/);
assert.match(archiveFn, /author_id = NULL/);
assert.match(archiveFn, /DELETE FROM public[.]character_illustration_cleanup_jobs/);
assert.doesNotMatch(archiveFn, /DELETE FROM public[.]characters/);
assert.doesNotMatch(archiveFn, /DELETE FROM storage[.]objects/);
assert.match(sql, /GRANT EXECUTE ON FUNCTION private[.]archive_account_characters[(]uuid[)][\s\S]*?TO service_role/);

const integrationPath = "supabase/drafts/prepare-account-deletion-character-preservation-integration.sql";
const integration = fs.readFileSync(integrationPath, "utf8");
assert.match(integration, /^-- DRAFT ONLY — NOT AN ACTIVE MIGRATION\./);
assert.match(integration, /CREATE OR REPLACE FUNCTION public[.]prepare_account_deletion[(]p_user_id uuid[)]/);
assert.match(integration, /SET search_path TO ''/);

// The existing deleting retry must not require a profile that may already be gone.
// A legacy deleting batch is healed only if still-owned character rows exist.
const deletingBranch = integration.match(/IF FOUND AND v_status = 'deleting' THEN[\s\S]*?RETURN QUERY SELECT v_batch_id, p_user_id, 'deleting'::text;/)?.[0];
assert.ok(deletingBranch, "deleting retry branch must exist");
assert.match(deletingBranch, /IF EXISTS [(][\s\S]*?c[.]author_id = p_user_id[\s\S]*?PERFORM private[.]archive_account_characters[(]p_user_id[)][;]/);
assert.ok(deletingBranch.indexOf("PERFORM private.archive_account_characters") < deletingBranch.indexOf("RETURN QUERY"));
assert.match(deletingBranch, /RETURN QUERY SELECT v_batch_id, p_user_id, 'deleting'::text/);

// Both non-terminal paths archive characters before billing cleanup/deleting state.
const existingBatchBranch = integration.match(/ELSIF FOUND THEN[\s\S]*?ELSE[\s\S]*?SELECT a[.]batch_id INTO v_batch_id/)?.[0];
assert.ok(existingBatchBranch, "existing batch branch must exist");
assert.match(existingBatchBranch, /PERFORM private[.]archive_account_characters[(]p_user_id[)][;]/);
const newBatchBranch = integration.match(/ELSE[\s\S]*?PERFORM private[.]archive_account_characters[(]p_user_id[)][;][\s\S]*?SELECT a[.]batch_id INTO v_batch_id/)?.[0];
assert.ok(newBatchBranch, "new batch branch must archive characters before archive batch creation");
assert.equal((integration.match(/PERFORM private[.]archive_account_characters[(]p_user_id[)][;]/g) || []).length, 3);

// Ensure the exact existing prepare flow still preserves financial/audit verification,
// removes only the deleting player's legacy conversations, and doesn't remove other
// players' chat_message_versions when they were merely edited by this account.
for (const pattern of [
  /chat_turn_charges/,
  /chat_turn_events/,
  /payload IS DISTINCT FROM pg_catalog[.]to_jsonb/,
  /DELETE FROM public[.]chat_turn_charges/,
  /DELETE FROM public[.]wallet_transactions/,
  /DELETE FROM public[.]conversations WHERE user_id = p_user_id/,
  /UPDATE public[.]chat_message_versions AS v[\s\S]*?SET edited_by = NULL/,
]) assert.match(integration, pattern);

// The worker's deleting recovery path must resume Auth/finalize only. It must not
// re-run archive/prepare after the request/profile may have disappeared.
const worker = fs.readFileSync("supabase/functions/_shared/account-deletion-worker.ts", "utf8");
const recoveryBranch = worker.match(/if [(]item[.]work_status === "deleting" && batchId[)][\s\S]*?continue;/)?.[0];
assert.ok(recoveryBranch, "worker deleting recovery branch must exist");
assert.match(recoveryBranch, /deps[.]deleteAuthUser/);
assert.match(recoveryBranch, /deps[.]finalize/);
assert.doesNotMatch(recoveryBranch, /deps[.]archive|deps[.]prepare/);

// Manually archived groups keep their existing memory-photo reads. Only deleted_at
// removes access; this draft does not widen upload/update/delete privileges.
const memoryPhotoDraft = fs.readFileSync(
  "supabase/drafts/chat-archive-memory-photo-read-access.sql",
  "utf8",
);
const tablePhotoStart = memoryPhotoDraft.indexOf("CREATE POLICY memory_photos_select_owner");
const storagePhotoDrop = memoryPhotoDraft.indexOf("DROP POLICY IF EXISTS memory_photo_objects_select_owner");
const tablePhotoSelect = memoryPhotoDraft.slice(tablePhotoStart, storagePhotoDrop);
assert.ok(tablePhotoStart >= 0 && storagePhotoDrop > tablePhotoStart, "memory photo table SELECT policy must be replaced");
assert.match(tablePhotoSelect, /owner_id = [(]SELECT auth[.]uid[(][)][)]/);
assert.match(tablePhotoSelect, /g[.]deleted_at IS NULL/);
assert.doesNotMatch(tablePhotoSelect, /g[.]archived_at/);
const storagePhotoStart = memoryPhotoDraft.indexOf("CREATE POLICY memory_photo_objects_select_owner");
const noWriteChanges = memoryPhotoDraft.indexOf("-- No INSERT, UPDATE, DELETE", storagePhotoStart);
const storagePhotoSelect = memoryPhotoDraft.slice(storagePhotoStart, noWriteChanges);
assert.ok(storagePhotoStart >= 0 && noWriteChanges > storagePhotoStart, "memory photo Storage SELECT policy must be replaced");
assert.match(storagePhotoSelect, /p[.]storage_path = objects[.]name/);
assert.match(storagePhotoSelect, /g[.]deleted_at IS NULL/);
assert.doesNotMatch(storagePhotoSelect, /g[.]archived_at/);
assert.doesNotMatch(memoryPhotoDraft, /FOR INSERT|FOR UPDATE|FOR DELETE/i);

// The 30-day purge worker is deployed but has no visible scheduler. Keep the
// proposed five-minute cron in a draft until the worker and deployment are accepted.
const purgeCronDraft = fs.readFileSync("supabase/drafts/chat-deletion-purge-cron.sql", "utf8");
assert.match(purgeCronDraft, /^-- DRAFT ONLY — NOT AN ACTIVE MIGRATION\./);
assert.match(purgeCronDraft, /cron[.]schedule[(]/);
assert.match(purgeCronDraft, /'poyozz-chat-deletion-purge'/);
assert.ok(purgeCronDraft.includes("'*/5 * * * *'"));
assert.match(purgeCronDraft, /chat_deletion_worker_service_role_key/);
assert.ok(purgeCronDraft.includes("left(decrypted_secret, 10) = 'sb_secret_'"));
assert.ok(purgeCronDraft.includes("/functions/v1/purge-chat-deletions"));
assert.match(purgeCronDraft, /WHERE EXISTS/);
assert.match(purgeCronDraft, /chat_storage_deletion_jobs/);
assert.doesNotMatch(purgeCronDraft, /sb_secret_[A-Za-z0-9_-]{20,}/);

const migrationsDir = "supabase/migrations";
const activeSql = fs.readdirSync(migrationsDir)
  .filter((name) => name.endsWith(".sql"))
  .map((name) => fs.readFileSync(path.join(migrationsDir, name), "utf8"))
  .join("\n");
assert.doesNotMatch(activeSql, /archive_account_characters|account_archived_at/);


const characterDeletionDraft = fs.readFileSync(
  "supabase/drafts/character-history-aware-deletion.sql",
  "utf8",
);
assert.ok(characterDeletionDraft.startsWith("-- DRAFT ONLY — NOT AN ACTIVE MIGRATION."));
assert.match(characterDeletionDraft, /CREATE TABLE IF NOT EXISTS public[.]character_asset_cleanup_jobs/);
assert.match(characterDeletionDraft, /ENABLE ROW LEVEL SECURITY/);
assert.match(characterDeletionDraft, /REVOKE ALL ON public[.]character_asset_cleanup_jobs FROM PUBLIC, anon, authenticated/);
assert.match(characterDeletionDraft, /CREATE OR REPLACE FUNCTION private[.]character_has_history[(]p_character_id uuid[)]/);
for (const table of [
  "chat_sessions", "chat_group_members", "chat_group_messages", "chat_groups",
  "conversations", "encounter_character_state", "encounter_diary",
  "encounter_turn_interaction_receipts", "encounter_session_lifecycle",
  "encounter_session_turns", "encounter_session_evaluation_jobs",
  "story_relationship_batches", "story_relationship_states", "character_comments",
]) {
  assert.match(characterDeletionDraft, new RegExp("public[.]" + table));
}
assert.match(characterDeletionDraft, /s[.]character_id = p_character_id/);
assert.doesNotMatch(characterDeletionDraft, /s[.]deleted_at IS NULL/);
assert.match(characterDeletionDraft, /v_first_published_at IS NULL AND NOT v_has_history/);
assert.match(characterDeletionDraft, /DELETE FROM public[.]characters WHERE id = p_character_id/);
assert.ok(characterDeletionDraft.includes("SET visibility = 'private',"));
assert.ok(characterDeletionDraft.includes("deletion_reason = 'author_deleted'"));
assert.match(characterDeletionDraft, /character-avatar-videos/);
assert.match(characterDeletionDraft, /character-illustrations/);
assert.ok(characterDeletionDraft.includes("auth.uid()::text || '/' || p_character_id::text"));
assert.match(characterDeletionDraft, /CREATE OR REPLACE FUNCTION public[.]claim_character_asset_cleanup_jobs/);
assert.match(characterDeletionDraft, /CREATE OR REPLACE FUNCTION public[.]finish_character_asset_cleanup_job/);
assert.match(characterDeletionDraft, /auth[.]jwt[(][)] ->> 'role'/);
assert.match(characterDeletionDraft, /TO service_role/);
assert.match(characterDeletionDraft, /dead_letter/);
assert.match(characterDeletionDraft, /claimed_at < pg_catalog[.]statement_timestamp[(][)] - interval '15 minutes'/);
const assetWorker = fs.readFileSync("supabase/functions/purge-character-assets/index.ts", "utf8");
const assetProcessor = fs.readFileSync("supabase/functions/_shared/character-asset-cleanup-worker.ts", "utf8");
assert.match(assetWorker, /withSupabase[(][{] auth: "secret:default" [}]/);
assert.match(assetWorker, /claim_character_asset_cleanup_jobs/);
assert.match(assetWorker, /finish_character_asset_cleanup_job/);
assert.match(assetWorker, /character_illustrations/);
assert.match(assetWorker, /avatar_video_path/);
assert.match(assetProcessor, /isSafeCharacterAssetJob/);
assert.match(assetProcessor, /asset_still_referenced/);
assert.match(assetProcessor, /unsafe_asset_path/);
assert.match(assetProcessor, /markJob[(]job[.]id, "failed"/);
const assetWorkerTests = fs.readFileSync("supabase/functions/_shared/character-asset-cleanup-worker.test.ts", "utf8");
assert.match(assetWorkerTests, /skips assets still referenced/);
assert.match(assetWorkerTests, /Storage errors for retry/);
assert.match(assetWorkerTests, /owner\/character scoped asset paths/);
assert.doesNotMatch(characterDeletionDraft, /DELETE FROM storage[.]objects/);
assert.ok(!characterDeletionDraft.includes("DELETE FROM storage.objects"));

console.log("Account and character deletion draft guards: passed (static only; no SQL execution).");

