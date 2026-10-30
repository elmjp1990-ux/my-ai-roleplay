-- Trusted chat mode marker. Existing sessions remain story mode by default.
-- Only trusted backend code using the service role may create an encounter-mode session.
ALTER TABLE public.chat_sessions
  ADD COLUMN IF NOT EXISTS chat_mode text NOT NULL DEFAULT 'story';

ALTER TABLE public.chat_sessions
  ADD CONSTRAINT chat_sessions_chat_mode_check
  CHECK (chat_mode IN ('story', 'encounter'));

CREATE INDEX IF NOT EXISTS chat_sessions_user_mode_active_idx
  ON public.chat_sessions (user_id, chat_mode, created_at DESC)
  WHERE deleted_at IS NULL;

COMMENT ON COLUMN public.chat_sessions.chat_mode IS
  'Trusted server-assigned mode. Existing sessions default to story; clients must never be allowed to upgrade a session to encounter mode.';

-- Explicitly deny direct client writes to this server-owned marker.
REVOKE UPDATE (chat_mode) ON TABLE public.chat_sessions FROM anon, authenticated;
