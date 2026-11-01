-- DRAFT ONLY — do not apply until migration history/replay workflow is reconciled.
-- PR #200 follow-up: remove excessive TRUNCATE from client-facing roles.
--
-- Current test-project read-only audit (2026-11-01) confirmed explicit
-- TRUNCATE privileges on eight existing public tables for anon and/or
-- authenticated. RLS does not apply to TRUNCATE.
--
-- This revokes only TRUNCATE from anon/authenticated across existing public
-- tables. It does not change SELECT/INSERT/UPDATE/DELETE, RLS policies,
-- service_role, or postgres privileges.
--
-- The existing postgres default-privilege migration already revokes all
-- table privileges from anon/authenticated for future public tables created
-- by postgres, so this draft intentionally does not alter default ACLs.

REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM anon, authenticated;

-- Required post-apply verification:
-- 1. Every public table: has_table_privilege('anon', oid, 'TRUNCATE') = false.
-- 2. Every public table: has_table_privilege('authenticated', oid, 'TRUNCATE') = false.
-- 3. service_role/postgres retain expected privileges.
-- 4. Existing intended client CRUD + RLS tests still pass.
-- 5. Record exact migration version and before/after counts.
