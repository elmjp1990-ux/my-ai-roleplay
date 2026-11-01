-- PR #200: additive foundation for one 30-day lifecycle across single and group chats.
-- This migration intentionally does not delete or rewrite existing chat data.
-- The durable queues have no FK to chat parents, profiles, or auth.users so later
-- character/account deletion cannot cascade away pending cleanup work.

ALTER TABLE public.chat_groups
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

COMMENT ON COLUMN public.chat_groups.deleted_at IS
  'Lifecycle soft-delete timestamp. Distinct from archived_at; ordinary access and writes must stop immediately when set.';

CREATE TABLE IF NOT EXISTS public.chat_deletion_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_type text NOT NULL
    CHECK (resource_type IN ('single_session', 'group')),
  resource_id uuid NOT NULL,
  owner_id uuid NOT NULL,
  deleted_at timestamptz NOT NULL,
  purge_after timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'processing', 'retry', 'completed', 'dead_letter')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at timestamptz,
  lease_until timestamptz,
  last_error_code text CHECK (last_error_code IS NULL OR char_length(last_error_code) <= 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chat_deletion_jobs_resource_unique UNIQUE (resource_type, resource_id),
  CONSTRAINT chat_deletion_jobs_retention_window_check
    CHECK (purge_after = deleted_at + interval '30 days'),
  CONSTRAINT chat_deletion_jobs_lease_state_check
    CHECK ((status = 'processing' AND lease_until IS NOT NULL)
        OR (status <> 'processing'))
);

COMMENT ON TABLE public.chat_deletion_jobs IS
  'Service-role-only durable lifecycle queue for 30-day single/group chat retention. No FK to chat/user parents by design.';
COMMENT ON COLUMN public.chat_deletion_jobs.owner_id IS
  'Immutable owner ID snapshot; intentionally has no FK to profiles/auth.users.';
COMMENT ON COLUMN public.chat_deletion_jobs.resource_id IS
  'Immutable chat session/group ID snapshot; intentionally has no FK to the chat parent.';

CREATE INDEX IF NOT EXISTS chat_deletion_jobs_due_idx
  ON public.chat_deletion_jobs (purge_after, next_attempt_at, created_at)
  WHERE status IN ('queued', 'retry');

CREATE INDEX IF NOT EXISTS chat_deletion_jobs_lease_idx
  ON public.chat_deletion_jobs (lease_until)
  WHERE status = 'processing';

CREATE TABLE IF NOT EXISTS public.chat_storage_deletion_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deletion_job_id uuid NOT NULL
    REFERENCES public.chat_deletion_jobs(id) ON DELETE CASCADE,
  bucket_id text NOT NULL
    CHECK (bucket_id = 'personax-memory-photos'),
  object_path text NOT NULL
    CHECK (char_length(object_path) BETWEEN 1 AND 1024),
  resource_type text NOT NULL
    CHECK (resource_type IN ('single_session', 'group')),
  resource_id uuid NOT NULL,
  owner_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'processing', 'retry', 'completed', 'dead_letter')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at timestamptz,
  lease_until timestamptz,
  last_error_code text CHECK (last_error_code IS NULL OR char_length(last_error_code) <= 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chat_storage_deletion_jobs_object_unique UNIQUE (bucket_id, object_path),
  CONSTRAINT chat_storage_deletion_jobs_lease_state_check
    CHECK ((status = 'processing' AND lease_until IS NOT NULL)
        OR (status <> 'processing'))
);

COMMENT ON TABLE public.chat_storage_deletion_jobs IS
  'Service-role-only retry queue for chat-memory Storage objects. Bucket allowlist excludes all character assets.';

CREATE INDEX IF NOT EXISTS chat_storage_deletion_jobs_due_idx
  ON public.chat_storage_deletion_jobs (next_attempt_at, created_at)
  WHERE status IN ('queued', 'retry');

CREATE INDEX IF NOT EXISTS chat_storage_deletion_jobs_lease_idx
  ON public.chat_storage_deletion_jobs (lease_until)
  WHERE status = 'processing';

ALTER TABLE public.chat_deletion_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_storage_deletion_jobs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.chat_deletion_jobs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.chat_storage_deletion_jobs FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.chat_deletion_jobs TO service_role;
GRANT ALL ON TABLE public.chat_storage_deletion_jobs TO service_role;
