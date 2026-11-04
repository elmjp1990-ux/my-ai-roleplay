-- PR #200: final least-privilege hardening for chat deletion lifecycle.
-- This is a fresh incremental migration generated with `supabase migration new`.
-- It does not rewrite or replay historical migrations.
--
-- TRUNCATE bypasses RLS; remove it from client roles across the exposed public
-- schema. Existing SELECT/INSERT/UPDATE/DELETE grants and RLS policies are unchanged.
--
-- Single/group chat parents must enter the 30-day lifecycle RPC. Neither clients
-- nor service_role may directly hard-delete these parents. The postgres-owned
-- SECURITY DEFINER day-30 purge RPC remains the privileged lifecycle boundary.

REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public
  FROM anon, authenticated;

REVOKE DELETE ON TABLE public.chat_sessions
  FROM PUBLIC, anon, authenticated, service_role;

REVOKE DELETE ON TABLE public.chat_groups
  FROM PUBLIC, anon, authenticated, service_role;
