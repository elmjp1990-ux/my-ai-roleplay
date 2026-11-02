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

const migrationsDir = "supabase/migrations";
const activeSql = fs.readdirSync(migrationsDir)
  .filter((name) => name.endsWith(".sql"))
  .map((name) => fs.readFileSync(path.join(migrationsDir, name), "utf8"))
  .join("\n");
assert.doesNotMatch(activeSql, /archive_account_characters/);
assert.match(sql, /Required follow-up integration/);
assert.match(sql, /Call private[.]archive_account_characters[(]p_user_id[)] inside the final/);

console.log("Account deletion character-preservation draft guard: passed (static only; no SQL execution).");
