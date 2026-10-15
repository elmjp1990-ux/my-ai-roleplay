-- READ-ONLY DIAGNOSTICS ONLY.
-- This file intentionally contains no DROP/CREATE/ALTER/UPDATE/DELETE statements.
--
-- Earlier draft proposed replacing owner policies on characters,
-- character_stories, and conversations based on the assumption that
-- account_must_be_active was permissive. Live metadata checked 2026-10-15
-- shows those policies are RESTRICTIVE for role authenticated. Do not apply
-- the old policy-replacement proposal without a fresh, command-by-command
-- RLS review. This diagnostic file does not prove effective access behavior;
-- use a disposable test account in a separate test project for behavioral tests.

-- 1) Inspect policies and role applicability on the three tables.
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('characters', 'character_stories', 'conversations')
ORDER BY tablename, policyname;

-- 2) Check RLS enablement and FORCE RLS state.
SELECT n.nspname AS schema_name,
       c.relname AS table_name,
       c.relrowsecurity AS rls_enabled,
       c.relforcerowsecurity AS force_rls
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('characters', 'character_stories', 'conversations')
ORDER BY c.relname;

-- 3) Read-only checklist for disposable-test validation (do not run against a real account):
-- - Active account: intended owner CRUD succeeds.
-- - Account with a deletion request: owner INSERT/UPDATE/DELETE is denied where required.
-- - Public approved-character/story reads remain available according to product policy.
-- - After a safe cancellation/recovery in the test project, intended owner access returns.
-- - Repeat for anon and authenticated roles separately; do not infer runtime behavior from
--   policy names alone.
--
-- No policy changes have been applied to Supabase.
