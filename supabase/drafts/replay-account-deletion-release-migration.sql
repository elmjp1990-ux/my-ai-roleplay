-- Apply the CLI-generated PR #200 incremental migration to the synthetic
-- current-state schema, run its effective ACL/behavior acceptance, then rollback.
-- This is disposable PostgreSQL only; never run against hosted Supabase.
\set ON_ERROR_STOP on
BEGIN;

-- Seed legacy rows before the migration installs first-publication origin triggers.
\i supabase/drafts/seed-character-deletion-legacy-fixtures.sql

\echo 'Applying PR #200 prerequisite migration: privilege hardening'
\i supabase/migrations/20261103195621_poyozz_chat_deletion_privilege_hardening.sql

\echo 'Applying PR #200 prerequisite migration: account auth-user existence guard'
\i supabase/migrations/20261104200000_account_is_active_auth_user_existence_guard.sql

\echo 'Applying CLI-generated character/account deletion and atomic lease migration'
\i supabase/migrations/20261104200100_poyozz_account_deletion_preservation_atomic_lease.sql

\echo 'Applying account-deletion schedule write-freeze migration'
\i supabase/migrations/20261104200200_account_deletion_character_schedule_write_freeze.sql
\echo 'Applying account-deletion character Storage write-freeze migration'
\i supabase/migrations/20261104200300_account_deletion_character_storage_write_freeze.sql

\echo 'Verify migration structure, RLS, grants, SECURITY DEFINER and search_path'
\i supabase/drafts/verify-deletion-draft-replay.sql

\echo 'Verify effective lease table/RPC privileges'
\i supabase/drafts/test-account-deletion-worker-lease-security.sql

\echo 'Run account-deletion schedule read/write freeze behavior'
\i supabase/drafts/test-account-deletion-character-schedule-write-freeze.sql

\echo 'Run account-deletion character child-table RLS freeze behavior'
\i supabase/drafts/test-account-deletion-character-child-rls-freeze.sql
\echo 'Run account-deletion character Storage write-freeze behavior'
\i supabase/drafts/test-account-deletion-character-storage-write-freeze.sql

\echo 'Run history-aware character deletion behavior against generated migration'
\i supabase/drafts/test-character-deletion-behavior.sql

\echo 'Run account character/chat/media preservation and retention behavior against generated migration'
\i supabase/drafts/test-account-deletion-character-preservation-behavior.sql

\echo 'Generated migration behavior and security assertions passed; rolling back all test DDL/data'
ROLLBACK;
