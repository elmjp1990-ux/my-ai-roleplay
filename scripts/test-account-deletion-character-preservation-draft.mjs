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
// Historical creator attribution is deliberately plain-text display name only.
assert.match(sql, /creator_display_name/);
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
// Account deletion preserves each work's original visibility/review state.
assert.doesNotMatch(archiveFn, /visibility\\s*=\\s*'private'/);
assert.match(archiveFn, /c[.]visibility AS current_visibility/);
assert.match(archiveFn, /'visibility', owned[.]current_visibility/);
assert.match(archiveFn, /'creatorDisplayName'/);
assert.match(archiveFn, /'creatorProfileAvailable', false/);
assert.match(archiveFn, /'characterStatus', 'offline'/);
assert.match(archiveFn, /'isOnline', false/);
assert.doesNotMatch(sql, /creator_handle_snapshot|creatorHandleSnapshot/);
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
assert.match(integration.trimEnd(), /\$function\$;$/);

// Account deletion also cascades through auth.users -> chat_sessions/chat_groups.
// The turn-statistics draft must snapshot every owned parent before prepare can
// permit Auth deletion, while skipping already-purged parents only with tombstone proof.
const accountHistoryDraft = fs.readFileSync(
  "supabase/drafts/chat-deletion-cumulative-turn-statistics-proposal.sql",
  "utf8",
);
const accountChatSnapshot = accountHistoryDraft.match(
  /CREATE OR REPLACE FUNCTION private[.]snapshot_account_chat_character_history[(][\s\S]*?p_user_id uuid[\s\S]*?\$function\$;/,
)?.[0];
assert.ok(accountChatSnapshot, "account deletion character-history snapshot helper must exist");
assert.match(accountChatSnapshot, /SECURITY DEFINER/);
assert.match(accountChatSnapshot, /SET search_path TO ''/);
assert.match(accountChatSnapshot, /FROM public[.]chat_sessions AS s[\s\S]*?FOR UPDATE/);
assert.match(accountChatSnapshot, /FROM public[.]chat_groups AS g[\s\S]*?FOR UPDATE/);
assert.match(accountChatSnapshot, /snapshot_chat_deletion_character_turn_stats/);
assert.match(accountChatSnapshot, /status = 'completed'[\s\S]*?chat_deletion_character_history/);
assert.doesNotMatch(accountChatSnapshot, /request_content|message content/i);
assert.equal(
  (integration.match(/PERFORM private[.]snapshot_account_chat_character_history[(]p_user_id[)][;]/g) || []).length,
  1,
  "account chat history must be snapshotted exactly once before batch handling",
);
assert.ok(
  integration.indexOf("PERFORM private.snapshot_account_chat_character_history(p_user_id);") <
    integration.indexOf("-- Lock/reuse this exact request's batch"),
  "account chat history snapshot must precede batch handling and Auth deletion",
);

// Group charges are FK-cascaded by both group and Auth deletion. Preserve the
// complete financial charge row and only minimal group-turn idempotency metadata.
assert.match(integration, /'chat_group_turn_charges'/);
assert.match(integration, /'chat_group_turns'/);
assert.match(integration, /ALTER TABLE public[.]account_deletion_archive_items[\s\S]*?CHECK [(]source_table IN/);
assert.match(integration, /pg_catalog[.]to_jsonb[(]gc[)]/);
assert.match(integration, /'request_key', gt[.]request_key/);
assert.match(integration, /'completed_at', gt[.]completed_at/);
assert.doesNotMatch(integration, /jsonb_build_object[\s\S]{0,250}request_content/);
assert.match(integration, /v_group_charge_source <> v_group_charge_archived/);
assert.match(integration, /v_group_turn_source <> v_group_turn_archived/);
assert.match(integration, /chat_group_turn_charges[\s\S]*?payload IS DISTINCT FROM pg_catalog[.]to_jsonb[(]gc[)]/);
assert.match(integration, /chat_group_turns[\s\S]*?payload IS DISTINCT FROM pg_catalog[.]jsonb_build_object/);

// The live account_is_active() still trusts auth.uid() plus absence of a pending
// request. Its replacement draft must additionally verify the Auth row, so a
// stale JWT cannot authorize work after Auth Admin deletion.
const activeGuard = fs.readFileSync(
  "supabase/drafts/account-is-active-auth-user-existence-guard.sql",
  "utf8",
);
assert.match(activeGuard, /^-- DRAFT ONLY/);
assert.match(activeGuard, /EXISTS [(][\s\S]*?FROM auth[.]users AS u[\s\S]*?u[.]id = auth[.]uid[(][)]/);
assert.match(activeGuard, /NOT EXISTS [(][\s\S]*?account_deletion_requests/);

// Existing-session media reads must use the same live-account gate; the
// Auth-user-existence guard above makes this stale-JWT safe.
assert.match(existingSessionFn, /public[.]account_is_active[(][)] IS TRUE/);

// Retained character child tables get restrictive pending-deletion gates.
const childWriteFreeze = fs.readFileSync(
  "supabase/drafts/account-deletion-character-child-write-freeze.sql",
  "utf8",
);
assert.match(childWriteFreeze, /^-- DRAFT ONLY — NOT AN ACTIVE MIGRATION[.]/);
for (const table of [
  "character_private_info",
  "character_schedules",
  "character_schedule_descriptions",
  "character_illustrations",
]) {
  const start = childWriteFreeze.indexOf("CREATE POLICY account_must_be_active");
  const tableStart = childWriteFreeze.indexOf("ON public." + table, start);
  const policyEnd = childWriteFreeze.indexOf("WITH CHECK (public.account_is_active())", tableStart);
  assert.ok(start >= 0 && tableStart > start && policyEnd > tableStart,
    table + " must have an account-active restrictive policy");
  assert.ok(childWriteFreeze.slice(start, policyEnd).includes("AS RESTRICTIVE"));
  assert.ok(childWriteFreeze.slice(start, policyEnd).includes("FOR ALL"));
  assert.ok(childWriteFreeze.slice(start, policyEnd).includes("TO authenticated"));
}

const startChatFn = sql.match(
  /CREATE OR REPLACE FUNCTION public[.]character_can_start_chat[(][\s\S]*?\$function\$;/,
)?.[0];
assert.ok(startChatFn, "single/story new-session eligibility helper must exist");
assert.match(startChatFn, /account_archived_at IS NULL/);
const encounterEligibilityFn = sql.match(
  /CREATE OR REPLACE FUNCTION public[.]can_open_encounter_session[(][\s\S]*?\$function\$;/,
)?.[0];
assert.ok(encounterEligibilityFn, "encounter new-session eligibility helper must exist");
assert.match(encounterEligibilityFn, /account_archived_at IS NULL/);
assert.match(archiveFn, /FOR UPDATE OF cs/);
assert.match(archiveFn, /FOR UPDATE OF st/);

const archivedEntryGuard = fs.readFileSync(
  "supabase/drafts/account-archived-character-session-insert-guard.sql",
  "utf8",
);
assert.match(archivedEntryGuard, /^-- DRAFT ONLY/);
const archivedEntryFn = archivedEntryGuard.match(
  /CREATE OR REPLACE FUNCTION private[.]reject_account_archived_character_entry[(][\s\S]*?\$function\$;/,
)?.[0];
assert.ok(archivedEntryFn, "database-level archived-character insert guard must exist");
assert.match(archivedEntryFn, /SECURITY DEFINER/);
assert.match(archivedEntryFn, /SET search_path TO ''/);
assert.match(archivedEntryFn, /account_archived_at IS NOT NULL/);
assert.match(archivedEntryFn, /deleted_at IS NOT NULL/);
assert.match(archivedEntryFn, /FOR KEY SHARE/);
assert.match(archivedEntryFn, /character_not_available/);
assert.match(archivedEntryFn, /world_character_id/);
assert.match(archivedEntryFn, /Serialize new-entry creation with/);
assert.match(archivedEntryFn, /character_stories AS cs/);
assert.match(archivedEntryFn, /to_jsonb[(]NEW[)] ->> 'story_id'/);
assert.match(
  archivedEntryGuard,
  /BEFORE INSERT OR UPDATE OF story_id ON public[.]conversations/,
);
assert.doesNotMatch(archivedEntryGuard, /ON public[.]messages/);
for (const [table, column] of [
  ["chat_sessions", "character_id"],
  ["chat_groups", "world_character_id"],
  ["chat_group_members", "character_id"],
  ["encounter_session_lifecycle", "character_id"],
  ["story_relationship_states", "character_id"],
]) {
  assert.match(
    archivedEntryGuard,
    new RegExp("BEFORE INSERT OR UPDATE OF " + column + " ON public[.]" + table),
  );
}
assert.doesNotMatch(archivedEntryGuard, /ON public[.]chat_messages/);
assert.doesNotMatch(archivedEntryGuard, /ON public[.]chat_group_messages/);
assert.match(archivedEntryGuard, /REVOKE ALL ON FUNCTION private[.]reject_account_archived_character_entry[(][)][\s\S]*?FROM PUBLIC, anon, authenticated, service_role/);


// Character hard-delete draft: never-published + zero-history is the only
// destructive exception. Unknown review states must remain soft-delete only.
const characterHardDeleteDraft = fs.readFileSync(
  "supabase/drafts/character-history-aware-deletion.sql",
  "utf8",
);
assert.match(characterHardDeleteDraft, /^-- DRAFT ONLY — NOT AN ACTIVE MIGRATION\./);
assert.match(characterHardDeleteDraft, /v_first_published_at IS NULL[\s\S]*?v_visibility = 'private'[\s\S]*?v_review_status = 'draft'[\s\S]*?NOT v_has_history/);
assert.doesNotMatch(characterHardDeleteDraft, /v_review_status <> 'approved'/);
for (const pattern of [
  /public[.]chat_sessions/,
  /public[.]chat_group_members/,
  /public[.]chat_group_messages/,
  /public[.]chat_deletion_character_history/,
  /public[.]chat_groups/,
  /public[.]conversations[\s\S]*?public[.]character_stories/,
  /public[.]encounter_character_state/,
  /public[.]encounter_diary/,
  /public[.]encounter_turn_interaction_receipts/,
  /public[.]encounter_session_lifecycle/,
  /public[.]encounter_session_turns/,
  /public[.]encounter_session_evaluation_jobs/,
  /public[.]story_relationship_batches/,
  /public[.]story_relationship_states/,
  /public[.]character_comments/,
]) assert.match(characterHardDeleteDraft, pattern);
assert.match(characterHardDeleteDraft, /character-avatar-videos/);
assert.match(characterHardDeleteDraft, /character-illustrations/);
assert.match(characterHardDeleteDraft, /CREATE TABLE IF NOT EXISTS public[.]character_asset_cleanup_jobs/);
assert.doesNotMatch(characterHardDeleteDraft, /DELETE FROM storage[.]objects/);

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
const cumulativeDeletionDraft = fs.readFileSync(
  "supabase/drafts/chat-deletion-cumulative-turn-statistics-proposal.sql",
  "utf8",
);
assert.match(cumulativeDeletionDraft, /CREATE TABLE IF NOT EXISTS public[.]chat_deletion_character_history/);
assert.match(cumulativeDeletionDraft, /INSERT INTO public[.]chat_deletion_character_history/);
assert.match(cumulativeDeletionDraft, /FROM public[.]chat_group_members/);
assert.match(cumulativeDeletionDraft, /FROM public[.]chat_group_messages/);
assert.match(cumulativeDeletionDraft, /FROM public[.]chat_deletion_character_turn_stats/);
const historyTombstone = cumulativeDeletionDraft.match(
  /CREATE TABLE IF NOT EXISTS public[.]chat_deletion_character_history\s*[(][\s\S]*?\);/,
)?.[0];
assert.ok(historyTombstone, "persistent character-use tombstone table must exist");
assert.doesNotMatch(historyTombstone, /REFERENCES/);

const singleDeleteFn = cumulativeDeletionDraft.match(
  /CREATE OR REPLACE FUNCTION public[.]delete_chat_session_content[(]p_session_id uuid[)][\s\S]*?\$function\$;/,
)?.[0];
assert.ok(singleDeleteFn, "single chat deletion RPC must exist");
assert.ok(
  singleDeleteFn.indexOf("PERFORM private.snapshot_chat_deletion_character_turn_stats") <
    singleDeleteFn.indexOf("UPDATE public.chat_sessions"),
  "single chat character history must be snapshotted before marking deleted",
);

const groupDeleteFn = cumulativeDeletionDraft.match(
  /CREATE OR REPLACE FUNCTION public[.]delete_chat_group_with_related_data[(]p_group_id uuid[)][\s\S]*?\$function\$;/,
)?.[0];
assert.ok(groupDeleteFn, "group chat deletion RPC must exist");
assert.ok(
  groupDeleteFn.indexOf("PERFORM private.snapshot_chat_deletion_character_turn_stats") <
    groupDeleteFn.indexOf("UPDATE public.chat_groups"),
  "group character history must be snapshotted before marking deleted",
);

const purgeFn = cumulativeDeletionDraft.match(
  /CREATE OR REPLACE FUNCTION public[.]purge_chat_deletion_job[(]p_job_id uuid[)][\s\S]*?\$function\$;/,
)?.[0];
assert.ok(purgeFn, "chat purge RPC must exist");
assert.ok(
  purgeFn.indexOf("PERFORM private.snapshot_chat_deletion_character_turn_stats") <
    purgeFn.indexOf("DELETE FROM public.chat_group_members"),
  "group character history must be snapshotted before member rows are purged",
);
assert.match(characterDeletionDraft, /public[.]chat_deletion_character_history/);
assert.ok(characterDeletionDraft.startsWith("-- DRAFT ONLY — NOT AN ACTIVE MIGRATION."));
assert.match(characterDeletionDraft, /CREATE TABLE IF NOT EXISTS public[.]character_asset_cleanup_jobs/);
assert.match(characterDeletionDraft, /ENABLE ROW LEVEL SECURITY/);
assert.match(characterDeletionDraft, /REVOKE ALL ON public[.]character_asset_cleanup_jobs FROM PUBLIC, anon, authenticated/);
assert.match(characterDeletionDraft, /CREATE OR REPLACE FUNCTION private[.]character_has_history[(]p_character_id uuid[)]/);
for (const table of [
  "chat_sessions", "chat_group_members", "chat_group_messages", "chat_groups",
  "chat_deletion_character_history",
  "conversations", "encounter_character_state", "encounter_diary",
  "encounter_turn_interaction_receipts", "encounter_session_lifecycle",
  "encounter_session_turns", "encounter_session_evaluation_jobs",
  "story_relationship_batches", "story_relationship_states", "character_comments",
]) {
  assert.match(characterDeletionDraft, new RegExp("public[.]" + table));
}
assert.match(characterDeletionDraft, /s[.]character_id = p_character_id/);
assert.doesNotMatch(characterDeletionDraft, /s[.]deleted_at IS NULL/);
assert.match(characterDeletionDraft, /v_first_published_at IS NULL[\s\S]*?v_visibility = 'private'[\s\S]*?v_review_status = 'draft'[\s\S]*?NOT v_has_history/);
assert.doesNotMatch(characterDeletionDraft, /v_review_status <> 'approved'/);
const publicationGuard = characterDeletionDraft.match(
  /CREATE OR REPLACE FUNCTION private[.]preserve_character_first_publication_timestamp[(][\\s\\S]*?\\$function\\$;/,
)?.[0];
assert.ok(publicationGuard, "immutable first-publication timestamp guard must exist");
assert.match(publicationGuard, /OLD[.]first_published_at IS NOT NULL/);
assert.match(publicationGuard, /NEW[.]first_published_at IS DISTINCT FROM OLD[.]first_published_at/);
assert.match(publicationGuard, /NEW[.]visibility = 'public'/);
assert.match(characterDeletionDraft, /BEFORE INSERT OR UPDATE OF first_published_at, visibility ON public[.]characters/);
assert.match(characterDeletionDraft, /character_first_publication_is_immutable/);
assert.match(characterDeletionDraft, /first transition to visibility='public' stamps first_published_at/);
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
const indexHtml = fs.readFileSync("index.html", "utf8");
assert.ok(indexHtml.includes("最後確認：刪除角色？公開列表會隱藏；若已有聊天、相遇或故事紀錄，系統會保留既有紀錄並封存角色。"));
assert.ok(indexHtml.includes("角色已刪除；有歷史紀錄的角色會保留既有內容"));
assert.ok(!indexHtml.includes("角色軟刪除失敗："));
const assetWorkerTests = fs.readFileSync("supabase/functions/_shared/character-asset-cleanup-worker.test.ts", "utf8");
assert.match(assetWorkerTests, /skips assets still referenced/);
assert.match(assetWorkerTests, /Storage errors for retry/);
assert.match(assetWorkerTests, /owner\/character scoped asset paths/);
assert.doesNotMatch(characterDeletionDraft, /DELETE FROM storage[.]objects/);
assert.ok(!characterDeletionDraft.includes("DELETE FROM storage.objects"));

console.log("Account and character deletion draft guards: passed (static only; no SQL execution).");

