-- DRAFT ONLY — NOT AN ACTIVE MIGRATION.
-- History-aware character deletion and private Storage cleanup queue.
-- Do not execute against the hosted test project. Replay only on a disposable
-- PostgreSQL database after the full migration ledger has been reconciled.
--
CREATE SCHEMA IF NOT EXISTS private;

-- Policy:
--   * Any publication OR any single/group/legacy/encounter/story/comment record
--     => soft-delete only; all existing player history remains.
--   * Never published AND absolutely no history => enqueue private assets and
--     hard-delete the character row in the same transaction.
--   * Account deletion is separate and MUST preserve characters and assets.
--   * Storage objects are never deleted by this SQL function.
--   * Requires chat_deletion_character_history from the cumulative chat-deletion draft.

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

-- Serialize reference creation against cleanup enqueue/removal. A reference writer
-- and the deletion transaction take the same transaction-scoped advisory lock
-- for the exact bucket/path. Once a cleanup job exists, that path can never be
-- reattached to a character or illustration.
CREATE OR REPLACE FUNCTION private.lock_character_asset_path(
  p_bucket_id text,
  p_object_path text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF p_bucket_id NOT IN ('character-illustrations', 'character-avatar-videos')
     OR p_object_path IS NULL OR p_object_path = '' THEN
    RAISE EXCEPTION 'invalid_character_asset_reference'
      USING ERRCODE = '22023';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_bucket_id || ':' || p_object_path, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION private.lock_character_asset_path(text, text)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION private.prevent_reuse_queued_character_asset()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_bucket_id text;
  v_object_path text;
BEGIN
  IF TG_TABLE_NAME = 'characters' THEN
    v_bucket_id := 'character-avatar-videos';
    v_object_path := NEW.avatar_video_path;
  ELSIF TG_TABLE_NAME = 'character_illustrations' THEN
    v_bucket_id := 'character-illustrations';
    v_object_path := NEW.storage_path;
  ELSE
    RAISE EXCEPTION 'unsupported_character_asset_reference_table';
  END IF;

  IF v_object_path IS NULL OR v_object_path = '' THEN
    RETURN NEW;
  END IF;

  PERFORM private.lock_character_asset_path(v_bucket_id, v_object_path);

  IF EXISTS (
    SELECT 1
    FROM public.character_asset_cleanup_jobs AS j
    WHERE j.bucket_id = v_bucket_id
      AND j.object_path = v_object_path
  ) THEN
    RAISE EXCEPTION 'character_asset_path_cleanup_already_queued'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.prevent_reuse_queued_character_asset()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS prevent_reuse_queued_character_avatar_video
  ON public.characters;
CREATE TRIGGER prevent_reuse_queued_character_avatar_video
  BEFORE INSERT OR UPDATE OF avatar_video_path
  ON public.characters
  FOR EACH ROW
  EXECUTE FUNCTION private.prevent_reuse_queued_character_asset();

DROP TRIGGER IF EXISTS prevent_reuse_queued_character_illustration
  ON public.character_illustrations;
CREATE TRIGGER prevent_reuse_queued_character_illustration
  BEFORE INSERT OR UPDATE OF storage_path
  ON public.character_illustrations
  FOR EACH ROW
  EXECUTE FUNCTION private.prevent_reuse_queued_character_asset();

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
    OR EXISTS (SELECT 1 FROM public.chat_deletion_character_history h
               WHERE h.character_id = p_character_id)
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

-- first_published_at is the durable evidence that a character was ever public.
-- The live author UPDATE policy does not restrict this column, so without this
-- trigger an author could clear the marker and make a previously published,
-- currently-private character eligible for hard deletion.
-- This private marker table is populated only by an AFTER INSERT trigger. That is
-- deliberate: BEFORE INSERT also runs for INSERT ... ON CONFLICT DO UPDATE and could
-- accidentally mark an existing legacy character as a newly-created private draft.
CREATE TABLE IF NOT EXISTS private.character_private_draft_origins (
  character_id uuid PRIMARY KEY
    REFERENCES public.characters(id) ON DELETE CASCADE,
  recorded_at timestamptz NOT NULL DEFAULT pg_catalog.statement_timestamp()
);

ALTER TABLE private.character_private_draft_origins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.character_private_draft_origins FROM PUBLIC, anon, authenticated, service_role;

-- Existing rows that are public at rollout are publication evidence. Legacy private
-- rows remain ineligible for hard-delete because their prior visibility cannot be proven.
UPDATE public.characters
SET first_published_at = pg_catalog.statement_timestamp()
WHERE visibility = 'public'
  AND first_published_at IS NULL;

CREATE OR REPLACE FUNCTION private.record_character_private_draft_origin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF NEW.visibility = 'private'
     AND NEW.review_status = 'draft'
     AND NEW.first_published_at IS NULL THEN
    INSERT INTO private.character_private_draft_origins (character_id)
    VALUES (NEW.id)
    ON CONFLICT (character_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.record_character_private_draft_origin()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS record_character_private_draft_origin
  ON public.characters;
CREATE TRIGGER record_character_private_draft_origin
  AFTER INSERT ON public.characters
  FOR EACH ROW
  EXECUTE FUNCTION private.record_character_private_draft_origin();

CREATE OR REPLACE FUNCTION private.preserve_character_first_publication_timestamp()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.first_published_at IS NOT NULL
     AND NEW.first_published_at IS DISTINCT FROM OLD.first_published_at THEN
    RAISE EXCEPTION 'character_first_publication_is_immutable'
      USING ERRCODE = '42501';
  END IF;

  -- Existing public rows are backfilled above. This additional OLD-state check
  -- protects any legacy public row missed by a partial/older rollout before it
  -- transitions to private. Caller-supplied publication timestamps are replaced.
  IF TG_OP = 'UPDATE' AND OLD.first_published_at IS NULL
     AND (OLD.visibility = 'public' OR NEW.visibility = 'public') THEN
    NEW.first_published_at := pg_catalog.statement_timestamp();
  ELSIF TG_OP = 'UPDATE' AND OLD.first_published_at IS NULL
        AND NEW.first_published_at IS NOT NULL THEN
    RAISE EXCEPTION 'character_first_publication_marker_is_server_managed'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.visibility = 'public' AND NEW.first_published_at IS NULL THEN
    NEW.first_published_at := pg_catalog.statement_timestamp();
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.preserve_character_first_publication_timestamp()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS preserve_character_first_publication_timestamp
  ON public.characters;
CREATE TRIGGER preserve_character_first_publication_timestamp
  BEFORE INSERT OR UPDATE OF first_published_at, visibility
  ON public.characters
  FOR EACH ROW
  EXECUTE FUNCTION private.preserve_character_first_publication_timestamp();

REVOKE DELETE ON TABLE public.characters FROM PUBLIC, anon, authenticated, service_role;

-- Legacy conversations cascade from character_stories. Prevent an author from
-- deleting a story template that still anchors another player's legacy transcript.
CREATE OR REPLACE FUNCTION private.prevent_character_story_delete_with_conversations()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.conversations AS cv
    WHERE cv.story_id = OLD.id
  ) THEN
    RAISE EXCEPTION 'character_story_has_chat_history'
      USING ERRCODE = '42501';
  END IF;
  RETURN OLD;
END;
$function$;

REVOKE ALL ON FUNCTION private.prevent_character_story_delete_with_conversations()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS prevent_character_story_delete_with_conversations
  ON public.character_stories;
CREATE TRIGGER prevent_character_story_delete_with_conversations
  BEFORE DELETE ON public.character_stories
  FOR EACH ROW
  EXECUTE FUNCTION private.prevent_character_story_delete_with_conversations();

-- Disposable PostgreSQL acceptance:
-- 1. First transition to visibility='public' stamps first_published_at.
-- 2. A later visibility='private' update retains the timestamp.
-- 3. Attempting to clear/change a non-NULL timestamp fails.
-- 4. A never-public private draft keeps first_published_at NULL.
-- 5. Direct DELETE from characters is denied to anon/authenticated.
-- 6. Deleting a story with a legacy conversation is rejected; unused story
--    templates may still be deleted.
-- 7. The history-aware hard-delete branch cannot be reached by clearing the marker.

CREATE OR REPLACE FUNCTION public.soft_delete_character(p_character_id uuid)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_author_id uuid;
  v_first_published_at timestamptz;
  v_private_draft_origin boolean;
  v_visibility text;
  v_review_status text;
  v_deleted_at timestamptz;
  v_avatar_video_path text;
  v_has_history boolean;
  v_asset record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF NOT public.account_is_active() THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  SELECT c.author_id, c.first_published_at,
         EXISTS (SELECT 1 FROM private.character_private_draft_origins d WHERE d.character_id = c.id),
         c.visibility, c.review_status, c.deleted_at, c.avatar_video_path
    INTO v_author_id, v_first_published_at, v_private_draft_origin,
         v_visibility, v_review_status, v_deleted_at, v_avatar_video_path
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

  -- Fail closed on any publication evidence. first_published_at is the durable
  -- marker, while the exact draft state is required. Unknown, NULL, pending,
  -- rejected, approved, or future review states fail closed to soft-delete.
  IF v_first_published_at IS NULL
     AND v_private_draft_origin
     AND v_visibility = 'private'
     AND v_review_status = 'draft'
     AND NOT v_has_history THEN
    -- Storage paths must be exact author/character/object paths. Unknown URL,
    -- base64, legacy or malformed formats fail closed and are not queued.
    IF v_avatar_video_path IS NOT NULL THEN
      IF v_avatar_video_path !~ (
        '^' || auth.uid()::text || '/' || p_character_id::text || '/[^/]+$'
      ) THEN
        RAISE EXCEPTION 'character_asset_path_not_owned_or_invalid'
          USING ERRCODE = '22023';
      END IF;
    END IF;

    -- Acquire the same advisory locks as reference-write triggers in stable
    -- order before queueing any object. This closes the check/remove race where
    -- another character could adopt the path after the worker's reference check.
    FOR v_asset IN
      SELECT 'character-avatar-videos'::text AS bucket_id,
             v_avatar_video_path AS object_path
      WHERE v_avatar_video_path IS NOT NULL
      UNION ALL
      SELECT 'character-illustrations'::text, ci.storage_path
      FROM public.character_illustrations AS ci
      WHERE ci.character_id = p_character_id
        AND ci.author_id = auth.uid()
      ORDER BY 1, 2
    LOOP
      PERFORM private.lock_character_asset_path(v_asset.bucket_id, v_asset.object_path);
    END LOOP;

    -- Queue both asset types only after all exact-path advisory locks are held.
    -- The reference-write trigger takes the same lock before checking the queue,
    -- so a concurrent reattachment either commits first (worker later skips the
    -- still-referenced object) or waits and is rejected after this job is visible.
    IF v_avatar_video_path IS NOT NULL THEN
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
             OR ci.storage_path IS NULL
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

  -- Snapshot writes follow the same parent-first order as chat writers.
  -- Existing sessions/groups stay active; only their character snapshot changes.
  PERFORM 1
  FROM public.chat_sessions AS session_parent
  WHERE session_parent.character_id = p_character_id
    AND session_parent.deleted_at IS NULL
  ORDER BY session_parent.id
  FOR UPDATE;

  PERFORM 1
  FROM public.chat_groups g
  WHERE g.deleted_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM public.chat_group_members gm
      WHERE gm.group_id = g.id
        AND gm.character_id = p_character_id
    )
  ORDER BY g.id
  FOR UPDATE;

  UPDATE public.chat_sessions AS parent_session
  SET character_snapshot = COALESCE(parent_session.character_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', 'private',
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    ),
    updated_at = v_deleted_at
  WHERE parent_session.character_id = p_character_id
    AND parent_session.deleted_at IS NULL;

  UPDATE public.chat_group_members gm
  SET character_snapshot = COALESCE(gm.character_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', 'private',
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    )
  WHERE gm.character_id = p_character_id
    AND EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = gm.group_id AND g.deleted_at IS NULL
    );

  UPDATE public.chat_group_messages gm
  SET speaker_snapshot = COALESCE(gm.speaker_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', 'private',
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    )
  WHERE gm.character_id = p_character_id
    AND EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = gm.group_id AND g.deleted_at IS NULL
    );

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
