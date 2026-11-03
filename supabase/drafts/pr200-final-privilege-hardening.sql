-- DRAFT ONLY — NOT AN ACTIVE MIGRATION.
-- Final least-privilege hardening to carry into a fresh, uniquely versioned
-- incremental migration after review. Never edit or reapply historical migrations.
--
-- 1) TRUNCATE bypasses RLS; remove it from client roles across the exposed
--    public schema. Existing CRUD grants and policies are intentionally unchanged.
-- 2) Single/group chat parents must enter the 30-day lifecycle RPC. Neither
--    clients nor service_role may directly hard-delete these parent rows.
--    The postgres-owned SECURITY DEFINER day-30 purge RPC remains responsible
--    for final parent DELETE after retention.
--
-- This file is tested only in the disposable current-state schema fixture.
-- Do not execute against hosted Supabase until the release migration is reviewed.

REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public
  FROM anon, authenticated;

REVOKE DELETE ON TABLE public.chat_sessions
  FROM PUBLIC, anon, authenticated, service_role;

REVOKE DELETE ON TABLE public.chat_groups
  FROM PUBLIC, anon, authenticated, service_role;
