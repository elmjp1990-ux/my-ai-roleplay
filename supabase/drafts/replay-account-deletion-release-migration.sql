-- Apply the CLI-generated PR #200 incremental migration to the synthetic
-- current-state schema, run its effective ACL/behavior acceptance, then rollback.
-- This is disposable PostgreSQL only; never run against hosted Supabase.
\set ON_ERROR_STOP on
BEGIN;

-- Seed legacy rows before the migration installs first-publication origin triggers.
\i supabase/drafts/seed-character-deletion-legacy-fixtures.sql

\echo 'Applying PR #200 prerequisite migration: privilege hardening'
\i supabase/migrations/20261103040547_poyozz_chat_deletion_privilege_hardening.sql

\echo 'Applying PR #200 prerequisite migration: account auth-user existence guard'
\i supabase/migrations/20261103090100_account_is_active_auth_user_existence_guard.sql

\echo 'Applying CLI-generated character/account deletion and atomic lease migration'
\i supabase/migrations/20261103115931_poyozz_account_deletion_preservation_atomic_lease.sql

\echo 'Verify migration structure, RLS, grants, SECURITY DEFINER and search_path'
\i supabase/drafts/verify-deletion-draft-replay.sql

\echo 'Verify effective lease table/RPC privileges'
\i supabase/drafts/test-account-deletion-worker-lease-security.sql

\echo 'Run history-aware character deletion behavior against generated migration'
\i supabase/drafts/test-character-deletion-behavior.sql

\echo 'Run account character/chat/media preservation and retention behavior against generated migration'
\i supabase/drafts/test-account-deletion-character-preservation-behavior.sql

\echo 'Generated migration behavior and security assertions passed; rolling back all test DDL/data'
ROLLBACK;
