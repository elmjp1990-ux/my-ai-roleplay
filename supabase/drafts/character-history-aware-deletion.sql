-- DRAFT ONLY — NOT AN ACTIVE MIGRATION.
-- History-aware character deletion and private Storage cleanup queue.
-- Do not execute against the hosted test project. Replay only on a disposable
-- PostgreSQL database after the full migration ledger has been reconciled.
--
-- Policy:
--   * Any publication OR any single/group/legacy/encounter/story/comment record
--     => soft-delete only; all existing player history remains.
--   * Never published AND absolutely no history => enqueue private assets and
--     hard-delete the character row in the same transaction.
--   * Account deletion is separate and MUST preserve characters and assets.
--   * Storage objects are never deleted by this SQL function.

CREATE TABLE IF NOT EXISTS public.character_asset_cleanup_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id text NOT NULL CHECK (bucket_id IN ('character-illustrations', 'character-avatar-videos')),
  object_path text NOT NULL,
  owner_id uuid NOT NULL,
  character_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'completed', 'skipped', 'failed', 'dead_letter')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at timestamptz NOT NULL DEFAULT now(),
  claimed_at timestamptz,
  completed_at timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (bucket_id, object_path)
);

ALTER TABLE public.character_asset_cleanup_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.character_asset_cleanup_jobs FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.character_asset_cleanup_jobs TO service_role;
CREATE INDEX IF NOT EXISTS character_asset_cleanup_jobs_due_idx
  ON public.character_asset_cleanup_jobs (available_at, created_at)
  WHERE status IN ('pending', 'failed');

CREATE OR REPLACE FUNCTION private.character_has_history(p_character_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT
    EXISTS (SELECT 1 FROM public.chat_sessions s
            WHERE s.character_id = p_character_id)
    OR EXISTS (SELECT 1 FROM public.chat_group_members gm
               WHERE gm.character_id = p_character_id)
    OR EXISTS (SELECT 1 FROM public.chat_group_messages gm
               WHERE gm.character_id = p_character_id)
    OR EXISTS (SELECT 1 FROM public.chat_groups g
               WHERE g.world_character_id = p_character_id)
    OR EXISTS (
      SELECT 1 FROM public.conversations cv
      JOIN public.character_stories cs ON cs.id = cv.story_id
      WHERE cs.character_id = p_character_id
    )
    OR EXISTS (
      SELECT 1 FROM public.encounter_character_state e
      WHERE e.character_id = p_character_id
    )
    OR EXISTS (SELECT 1 FROM public.encounter_diary e
               WHERE e.character_id = p_character_id)
    OR EXISTS (SELECT 1 FROM public.encounter_turn_interaction_receipts e
               WHERE e.character_id = p_character_id)
    OR EXISTS (SELECT 1 FROM public.encounter_session_lifecycle e
               WHERE e.character_id = p_character_id)
    OR EXISTS (SELECT 1 FROM public.encounter_session_turns e
               WHERE e.character_id = p_character_id)
    OR EXISTS (SELECT 1 FROM public.encounter_session_evaluation_jobs e
               WHERE e.character_id = p_character_id)
    OR EXISTS (SELECT 1 FROM public.story_relationship_batches e
               WHERE e.character_id = p_character_id)
    OR EXISTS (SELECT 1 FROM public.story_relationship_states e
               WHERE e.character_id = p_character_id)
    OR EXISTS (SELECT 1 FROM public.character_comments c
               WHERE c.character_id = p_character_id);
$function$;

REVOKE ALL ON FUNCTION private.character_has_history(uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.soft_delete_character(p_character_id uuid)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_author_id uuid;
  v_first_published_at timestamptz;
  v_deleted_at timestamptz;
  v_avatar_video_path text;
  v_has_history boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF NOT public.account_is_active() THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  SELECT c.author_id, c.first_published_at, c.deleted_at, c.avatar_video_path
    INTO v_author_id, v_first_published_at, v_deleted_at, v_avatar_video_path
  FROM public.characters c
  WHERE c.id = p_character_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Character not found.';
  END IF;
  IF v_author_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Not allowed to delete this character.' USING ERRCODE = '42501';
  END IF;
  IF v_deleted_at IS NOT NULL THEN
    RETURN v_deleted_at;
  END IF;

  v_deleted_at := pg_catalog.statement_timestamp();
  v_has_history := private.character_has_history(p_character_id);

  -- Only a never-published character with no trace of player activity can be
  -- physically removed. first_published_at is a permanent publication marker.
  IF v_first_published_at IS NULL AND NOT v_has_history THEN
    -- Storage paths must be exact author/character/object paths. Unknown URL,
    -- base64, legacy or malformed formats fail closed and are not queued.
    IF v_avatar_video_path IS NOT NULL THEN
      IF v_avatar_video_path !~ (
        '^' || auth.uid()::text || '/' || p_character_id::text || '/[^/]+$'
      ) THEN
        RAISE EXCEPTION 'character_asset_path_not_owned_or_invalid'
          USING ERRCODE = '22023';
      END IF;
      INSERT INTO public.character_asset_cleanup_jobs
        (bucket_id, object_path, owner_id, character_id)
      VALUES ('character-avatar-videos', v_avatar_video_path, auth.uid(), p_character_id)
      ON CONFLICT (bucket_id, object_path) DO NOTHING;
    END IF;

    INSERT INTO public.character_asset_cleanup_jobs
      (bucket_id, object_path, owner_id, character_id)
    SELECT 'character-illustrations', ci.storage_path, auth.uid(), p_character_id
    FROM public.character_illustrations ci
    WHERE ci.character_id = p_character_id
      AND ci.author_id = auth.uid()
      AND ci.storage_path ~ (
        '^' || auth.uid()::text || '/' || p_character_id::text || '/[^/]+$'
      )
    ON CONFLICT (bucket_id, object_path) DO NOTHING;

    -- An unexpected illustration path must not be silently orphaned.
    IF EXISTS (
      SELECT 1 FROM public.character_illustrations ci
      WHERE ci.character_id = p_character_id
        AND (ci.author_id IS DISTINCT FROM auth.uid()
             OR ci.storage_path !~ (
               '^' || auth.uid()::text || '/' || p_character_id::text || '/[^/]+$'
             ))
    ) THEN
      RAISE EXCEPTION 'character_illustration_path_not_owned_or_invalid'
        USING ERRCODE = '22023';
    END IF;

    DELETE FROM public.characters WHERE id = p_character_id;
    RETURN v_deleted_at;
  END IF;

  -- Any published or historically used character is archived, never cascaded.
  UPDATE public.characters
  SET visibility = 'private',
      review_status = 'draft',
      deleted_at = v_deleted_at,
      deletion_reason = 'author_deleted'
  WHERE id = p_character_id;

  UPDATE public.character_stories
  SET visibility = 'private'
  WHERE character_id = p_character_id;

  UPDATE public.chat_sessions cs
  SET character_snapshot = COALESCE(cs.character_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', 'private',
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    ),
    updated_at = v_deleted_at
  WHERE cs.character_id = p_character_id;

  UPDATE public.chat_group_members gm
  SET character_snapshot = COALESCE(gm.character_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', 'private',
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    )
  WHERE gm.character_id = p_character_id;

  UPDATE public.chat_group_messages gm
  SET speaker_snapshot = COALESCE(gm.speaker_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', 'private',
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    )
  WHERE gm.character_id = p_character_id;

  RETURN v_deleted_at;
END;
$function$;

-- Preserve the existing public RPC call contract, but don't broaden execution.
REVOKE ALL ON FUNCTION public.soft_delete_character(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.soft_delete_character(uuid) TO authenticated;

-- Service-only claim/finalize endpoints for a future Edge worker.
-- The worker must verify that the path is not referenced by another live character
-- or illustration before Storage.remove(); bucket IDs are allowlisted above.
CREATE OR REPLACE FUNCTION public.claim_character_asset_cleanup_jobs(p_limit integer DEFAULT 50)
RETURNS TABLE(id uuid, bucket_id text, object_path text, owner_id uuid, character_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF (auth.jwt() ->> 'role') IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  UPDATE public.character_asset_cleanup_jobs j
  SET status = 'dead_letter',
      claimed_at = NULL,
      last_error = COALESCE(j.last_error, 'lease_expired_after_max_attempts'),
      updated_at = pg_catalog.statement_timestamp()
  WHERE j.status = 'processing'
    AND j.claimed_at < pg_catalog.statement_timestamp() - interval '15 minutes'
    AND j.attempts >= 8;

  RETURN QUERY
  WITH due AS (
    SELECT j.id
    FROM public.character_asset_cleanup_jobs j
    WHERE (
        (j.status IN ('pending', 'failed') AND j.available_at <= pg_catalog.statement_timestamp())
        OR (j.status = 'processing' AND j.claimed_at < pg_catalog.statement_timestamp() - interval '15 minutes')
      )
      AND j.attempts < 8
    ORDER BY j.created_at
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 100))
  )
  UPDATE public.character_asset_cleanup_jobs j
  SET status = 'processing',
      attempts = j.attempts + 1,
      claimed_at = pg_catalog.statement_timestamp(),
      updated_at = pg_catalog.statement_timestamp()
  FROM due
  WHERE j.id = due.id
  RETURNING j.id, j.bucket_id, j.object_path, j.owner_id, j.character_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.finish_character_asset_cleanup_job(
  p_job_id uuid,
  p_status text,
  p_error text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF (auth.jwt() ->> 'role') IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('completed', 'skipped', 'failed', 'dead_letter') THEN
    RAISE EXCEPTION 'invalid_cleanup_status' USING ERRCODE = '22023';
  END IF;
  UPDATE public.character_asset_cleanup_jobs j
  SET status = CASE WHEN p_status = 'failed' AND j.attempts >= 8 THEN 'dead_letter' ELSE p_status END,
      last_error = CASE WHEN p_status IN ('failed', 'dead_letter') THEN left(COALESCE(p_error, 'unknown'), 1000) ELSE NULL END,
      available_at = CASE WHEN p_status = 'failed'
        THEN pg_catalog.statement_timestamp() + pg_catalog.make_interval(mins => LEAST(60, (2 ^ LEAST(j.attempts, 6))::integer))
        ELSE j.available_at END,
      completed_at = CASE WHEN p_status IN ('completed', 'skipped') THEN pg_catalog.statement_timestamp() ELSE NULL END,
      claimed_at = NULL,
      updated_at = pg_catalog.statement_timestamp()
  WHERE j.id = p_job_id AND j.status = 'processing';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cleanup_job_not_claimed' USING ERRCODE = 'P0002';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_character_asset_cleanup_jobs(integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finish_character_asset_cleanup_job(uuid, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_character_asset_cleanup_jobs(integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.finish_character_asset_cleanup_job(uuid, text, text)
  TO service_role;

-- Not yet included: Storage worker deployment/scheduler. Pending jobs intentionally
-- retain their objects until an audited Edge worker with reference checks is ready.
