-- DRAFT ONLY — NOT AN ACTIVE MIGRATION.
-- Prevent client-side hard deletion of active single-chat parents.
-- The user-facing delete path must call delete_chat_session_content(), which
-- marks the session deleted and enqueues the shared 30-day retention job.
-- The service-owned day-30 purge RPC remains responsible for final DELETE.
-- Do not apply until migration provenance and disposable PostgreSQL replay pass.

REVOKE DELETE ON TABLE public.chat_sessions
  FROM PUBLIC, anon, authenticated, service_role;

-- Group parents carry the same 30-day retention contract. A privileged backend
-- must not bypass the group soft-delete RPC and cascade its history immediately.
REVOKE DELETE ON TABLE public.chat_groups
  FROM PUBLIC, anon, authenticated, service_role;

-- No DELETE RLS policy is added. The existing soft-delete RPC remains the
-- client-facing lifecycle entrypoint; postgres-owned SECURITY DEFINER purge
-- functions continue to perform the final relational DELETE after retention.
