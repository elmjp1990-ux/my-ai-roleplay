-- Persist failed character illustration Storage deletions so they can be retried.
-- This table contains only the owner's object path and retry metadata.
CREATE TABLE IF NOT EXISTS public.character_illustration_cleanup_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  author_id uuid NOT NULL,
  storage_path text NOT NULL,
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error text CHECK (last_error IS NULL OR char_length(last_error) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT character_illustration_cleanup_jobs_owner_path_unique
    UNIQUE (author_id, storage_path),
  CONSTRAINT character_illustration_cleanup_jobs_owner_path_check
    CHECK (
      storage_path ~ (
        '^' || author_id::text ||
        '/[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}\.(jpg|jpeg|png|webp)$'
      )
    )
);

CREATE INDEX IF NOT EXISTS character_illustration_cleanup_jobs_author_created_idx
  ON public.character_illustration_cleanup_jobs (author_id, created_at);

ALTER TABLE public.character_illustration_cleanup_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.character_illustration_cleanup_jobs FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.character_illustration_cleanup_jobs TO authenticated;

DROP POLICY IF EXISTS character_illustration_cleanup_jobs_select_own
  ON public.character_illustration_cleanup_jobs;
CREATE POLICY character_illustration_cleanup_jobs_select_own
  ON public.character_illustration_cleanup_jobs
  FOR SELECT TO authenticated
  USING (author_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS character_illustration_cleanup_jobs_insert_own
  ON public.character_illustration_cleanup_jobs;
CREATE POLICY character_illustration_cleanup_jobs_insert_own
  ON public.character_illustration_cleanup_jobs
  FOR INSERT TO authenticated
  WITH CHECK (
    author_id = (SELECT auth.uid())
    AND left(storage_path, length((SELECT auth.uid())::text) + 1)
      = (SELECT auth.uid())::text || '/'
  );

DROP POLICY IF EXISTS character_illustration_cleanup_jobs_update_own
  ON public.character_illustration_cleanup_jobs;
CREATE POLICY character_illustration_cleanup_jobs_update_own
  ON public.character_illustration_cleanup_jobs
  FOR UPDATE TO authenticated
  USING (author_id = (SELECT auth.uid()))
  WITH CHECK (
    author_id = (SELECT auth.uid())
    AND left(storage_path, length((SELECT auth.uid())::text) + 1)
      = (SELECT auth.uid())::text || '/'
  );

DROP POLICY IF EXISTS character_illustration_cleanup_jobs_delete_own
  ON public.character_illustration_cleanup_jobs;
CREATE POLICY character_illustration_cleanup_jobs_delete_own
  ON public.character_illustration_cleanup_jobs
  FOR DELETE TO authenticated
  USING (author_id = (SELECT auth.uid()));
