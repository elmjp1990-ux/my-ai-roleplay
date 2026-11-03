-- Apply both deletion drafts and execute behavior tests inside one disposable transaction.
-- The final ROLLBACK removes every draft object and every synthetic test row.
\set ON_ERROR_STOP on
BEGIN;
\echo 'Applying cumulative chat deletion character-history snapshot draft'
\i supabase/drafts/chat-deletion-cumulative-turn-statistics-proposal.sql
\i supabase/migrations/20261103040547_poyozz_chat_deletion_privilege_hardening.sql
\echo 'Seeding legacy character rows before the publication/origin triggers exist'
\i supabase/drafts/seed-character-deletion-legacy-fixtures.sql
\echo 'Applying character history-aware deletion draft'
\i supabase/drafts/character-history-aware-deletion.sql
\echo 'Bootstrapping disposable Storage metadata schema for RLS policy replay'
CREATE SCHEMA IF NOT EXISTS storage;
DO $storage_stub$
BEGIN
  -- Supabase Local already owns storage.objects; do not attempt CREATE on its
  -- protected storage schema. Plain disposable PostgreSQL needs only this stub.
  IF pg_catalog.to_regclass('storage.objects') IS NULL THEN
    CREATE TABLE storage.objects (bucket_id text NOT NULL, name text NOT NULL);
  END IF;
END;
$storage_stub$;
\echo 'Applying account deletion character preservation and safe Auth detachment draft'
\i supabase/drafts/account-deletion-character-preservation-draft.sql
\echo 'Applying stale-JWT Auth-user existence guard'
\i supabase/drafts/account-is-active-auth-user-existence-guard.sql
\echo 'Applying database guard against new sessions for archived characters'
\i supabase/drafts/account-archived-character-session-insert-guard.sql
\echo 'Applying complete prepare_account_deletion integration draft'
\i supabase/drafts/prepare-account-deletion-character-preservation-integration.sql
\echo 'Applying existing-chat continuation writer draft (single/group deletion behavior remains isolated to disposable replay)'
\i supabase/drafts/character-deletion-existing-chat-continuation.sql
\echo 'Verifying draft tables, triggers, RLS and ACLs before behavior tests'
\i supabase/drafts/verify-deletion-draft-replay.sql
\echo 'Running hard-delete, soft-delete, single/group continuation, history, publication and asset path behavior tests'
\i supabase/drafts/test-character-deletion-behavior.sql
\echo 'Running account deletion character/media/chat preservation integration behavior tests'
\i supabase/drafts/test-account-deletion-character-preservation-behavior.sql
\echo 'All disposable character deletion behavior assertions passed; rolling back all draft DDL and test rows'
ROLLBACK;
