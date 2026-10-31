-- Correct the cleanup path check to match UUID filenames followed by a literal extension dot.
ALTER TABLE public.character_illustration_cleanup_jobs
  DROP CONSTRAINT IF EXISTS character_illustration_cleanup_jobs_owner_path_check;

ALTER TABLE public.character_illustration_cleanup_jobs
  ADD CONSTRAINT character_illustration_cleanup_jobs_owner_path_check
  CHECK (
    storage_path ~ (
      '^' || author_id::text ||
      '/[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}[.](jpg|jpeg|png|webp)$'
    )
  );
