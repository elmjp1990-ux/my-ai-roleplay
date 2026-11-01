-- DRAFT ONLY — PR #200 cumulative turn-stat retention proposal.
-- Reviewed against read-only live test-project definitions on 2026-11-01.
-- DO NOT move into supabase/migrations or apply to any hosted DB until:
--   1) migration provenance/version collision is reconciled,
--   2) exact local Supabase CLI replay succeeds,
--   3) disposable fixture tests below pass.
--
-- Purpose:
--   * Preserve per-character cumulative assistant-turn counts when a single or
--     group chat is soft-deleted and later purged.
--   * Exclude deleted parent groups from live-message counts.
--   * Keep only aggregate counts and minimal tombstone linkage, never message text.
--   * Backfill legacy deleted sessions which predate chat_deletion_jobs.
--
-- The snapshot is written in the same transaction as the player delete RPC,
-- after the parent row has been locked and before deleted_at is set. All writer
-- paths must continue to lock the same parent row, so no post-snapshot writes
-- can slip in. The purge worker repeats the snapshot idempotently as a safety
-- net for older queued jobs.

CREATE TABLE IF NOT EXISTS public.chat_deletion_character_turn_stats (
  resource_type text NOT NULL
    CHECK (resource_type IN ('single_session', 'group')),
  resource_id uuid NOT NULL,
  owner_id uuid NOT NULL,
  character_id uuid NOT NULL,
  turn_count bigint NOT NULL CHECK (turn_count > 0),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT chat_deletion_character_turn_stats_resource_character_key
    UNIQUE (resource_type, resource_id, character_id)
);

CREATE INDEX IF NOT EXISTS chat_deletion_character_turn_stats_character_idx
  ON public.chat_deletion_character_turn_stats (character_id);

ALTER TABLE public.chat_deletion_character_turn_stats ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.chat_deletion_character_turn_stats
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE public.chat_deletion_character_turn_stats IS
  'Minimal per-character aggregate counts retained after chat deletion; contains no transcript or message content. Service access is through postgres-owned SECURITY DEFINER functions only.';

-- Internal helper. No client-facing EXECUTE grant. It is invoked by existing
-- postgres-owned SECURITY DEFINER deletion functions and the purge worker.
CREATE OR REPLACE FUNCTION private.snapshot_chat_deletion_character_turn_stats(
  p_resource_type text,
  p_resource_id uuid,
  p_owner_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF p_resource_type = 'single_session' THEN
    INSERT INTO public.chat_deletion_character_turn_stats (
      resource_type, resource_id, owner_id, character_id, turn_count
    )
    SELECT
      'single_session',
      s.id,
      s.user_id,
      s.character_id,
      pg_catalog.count(m.id)::bigint
    FROM public.chat_sessions AS s
    LEFT JOIN public.chat_messages AS m
      ON m.session_id = s.id
     AND m.role = 'assistant'
     AND m.deleted_at IS NULL
    WHERE s.id = p_resource_id
      AND s.user_id = p_owner_id
      AND s.character_id IS NOT NULL
    GROUP BY s.id, s.user_id, s.character_id
    HAVING pg_catalog.count(m.id) > 0
    ON CONFLICT (resource_type, resource_id, character_id) DO NOTHING;

  ELSIF p_resource_type = 'group' THEN
    INSERT INTO public.chat_deletion_character_turn_stats (
      resource_type, resource_id, owner_id, character_id, turn_count
    )
    SELECT
      'group',
      g.id,
      g.owner_id,
      gm.character_id,
      pg_catalog.count(gm.id)::bigint
    FROM public.chat_groups AS g
    JOIN public.chat_group_messages AS gm
      ON gm.group_id = g.id
     AND gm.speaker_type = 'character'
     AND gm.deleted_at IS NULL
     AND gm.character_id IS NOT NULL
    WHERE g.id = p_resource_id
      AND g.owner_id = p_owner_id
    GROUP BY g.id, g.owner_id, gm.character_id
    HAVING pg_catalog.count(gm.id) > 0
    ON CONFLICT (resource_type, resource_id, character_id) DO NOTHING;

  ELSE
    RAISE EXCEPTION 'unsupported_chat_resource_type' USING ERRCODE = '22023';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION private.snapshot_chat_deletion_character_turn_stats(text, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

-- Backfill any already soft-deleted parents before the new count RPCs start
-- including archived statistics. Idempotent by the resource/character key.
INSERT INTO public.chat_deletion_character_turn_stats (
  resource_type, resource_id, owner_id, character_id, turn_count
)
SELECT
  'single_session',
  s.id,
  s.user_id,
  s.character_id,
  pg_catalog.count(m.id)::bigint
FROM public.chat_sessions AS s
JOIN public.chat_messages AS m
  ON m.session_id = s.id
 AND m.role = 'assistant'
 AND m.deleted_at IS NULL
WHERE s.deleted_at IS NOT NULL
  AND s.character_id IS NOT NULL
GROUP BY s.id, s.user_id, s.character_id
HAVING pg_catalog.count(m.id) > 0
ON CONFLICT (resource_type, resource_id, character_id) DO NOTHING;

INSERT INTO public.chat_deletion_character_turn_stats (
  resource_type, resource_id, owner_id, character_id, turn_count
)
SELECT
  'group',
  g.id,
  g.owner_id,
  gm.character_id,
  pg_catalog.count(gm.id)::bigint
FROM public.chat_groups AS g
JOIN public.chat_group_messages AS gm
  ON gm.group_id = g.id
 AND gm.speaker_type = 'character'
 AND gm.deleted_at IS NULL
 AND gm.character_id IS NOT NULL
WHERE g.deleted_at IS NOT NULL
GROUP BY g.id, g.owner_id, gm.character_id
HAVING pg_catalog.count(gm.id) > 0
ON CONFLICT (resource_type, resource_id, character_id) DO NOTHING;

-- Legacy deleted sessions without a queue job must join the same 30-day
-- lifecycle. The 30-day deadline is based on their original deleted_at.
INSERT INTO public.chat_deletion_jobs (
  resource_type, resource_id, owner_id, deleted_at, purge_after, status
)
SELECT
  'single_session',
  s.id,
  s.user_id,
  s.deleted_at,
  s.deleted_at + interval '30 days',
  'queued'
FROM public.chat_sessions AS s
WHERE s.deleted_at IS NOT NULL
ON CONFLICT (resource_type, resource_id) DO NOTHING;

INSERT INTO public.chat_deletion_jobs (
  resource_type, resource_id, owner_id, deleted_at, purge_after, status
)
SELECT
  'group',
  g.id,
  g.owner_id,
  g.deleted_at,
  g.deleted_at + interval '30 days',
  'queued'
FROM public.chat_groups AS g
WHERE g.deleted_at IS NOT NULL
ON CONFLICT (resource_type, resource_id) DO NOTHING;

-- Fail closed if any legacy photo path violates the existing owner-prefix rule.
DO $block$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.chat_memory_photos AS p
    JOIN public.chat_deletion_jobs AS j
      ON j.resource_type = 'single_session'
     AND j.resource_id = p.session_id
    WHERE p.chat_type = 'single'
      AND (p.owner_id IS DISTINCT FROM j.owner_id
        OR pg_catalog.left(p.storage_path, pg_catalog.char_length(j.owner_id::text) + 1)
           <> j.owner_id::text || '/')
  ) OR EXISTS (
    SELECT 1
    FROM public.chat_memory_photos AS p
    JOIN public.chat_deletion_jobs AS j
      ON j.resource_type = 'group'
     AND j.resource_id = p.group_id
    WHERE p.chat_type = 'group'
      AND (p.owner_id IS DISTINCT FROM j.owner_id
        OR pg_catalog.left(p.storage_path, pg_catalog.char_length(j.owner_id::text) + 1)
           <> j.owner_id::text || '/')
  ) THEN
    RAISE EXCEPTION 'chat_storage_path_owner_mismatch';
  END IF;
END;
$block$;

INSERT INTO public.chat_storage_deletion_jobs (
  deletion_job_id, bucket_id, object_path, resource_type, resource_id, owner_id
)
SELECT
  j.id,
  'personax-memory-photos',
  p.storage_path,
  'single_session',
  p.session_id,
  p.owner_id
FROM public.chat_memory_photos AS p
JOIN public.chat_deletion_jobs AS j
  ON j.resource_type = 'single_session'
 AND j.resource_id = p.session_id
WHERE p.chat_type = 'single'
ON CONFLICT (bucket_id, object_path) DO NOTHING;

INSERT INTO public.chat_storage_deletion_jobs (
  deletion_job_id, bucket_id, object_path, resource_type, resource_id, owner_id
)
SELECT
  j.id,
  'personax-memory-photos',
  p.storage_path,
  'group',
  p.group_id,
  p.owner_id
FROM public.chat_memory_photos AS p
JOIN public.chat_deletion_jobs AS j
  ON j.resource_type = 'group'
 AND j.resource_id = p.group_id
WHERE p.chat_type = 'group'
ON CONFLICT (bucket_id, object_path) DO NOTHING;

-- Existing player deletion RPCs, with only the snapshot call added.
CREATE OR REPLACE FUNCTION public.delete_chat_session_content(p_session_id uuid)
RETURNS TABLE(storage_path text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_owner_id uuid;
  v_deleted_at timestamptz;
  v_job_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests r
    WHERE r.user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  SELECT s.user_id, s.deleted_at
    INTO v_owner_id, v_deleted_at
  FROM public.chat_sessions s
  WHERE s.id = p_session_id
  FOR UPDATE;

  IF NOT FOUND OR v_owner_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'session_not_found_or_not_owned' USING ERRCODE = '42501';
  END IF;

  v_deleted_at := COALESCE(v_deleted_at, pg_catalog.statement_timestamp());

  INSERT INTO public.chat_deletion_jobs (
    resource_type, resource_id, owner_id, deleted_at, purge_after, status
  )
  VALUES (
    'single_session', p_session_id, v_user_id, v_deleted_at,
    v_deleted_at + interval '30 days', 'queued'
  )
  ON CONFLICT (resource_type, resource_id) DO NOTHING;

  SELECT j.id
    INTO v_job_id
  FROM public.chat_deletion_jobs j
  WHERE j.resource_type = 'single_session'
    AND j.resource_id = p_session_id
    AND j.owner_id = v_user_id
    AND j.deleted_at = v_deleted_at
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'chat_deletion_job_conflict' USING ERRCODE = '40001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.chat_memory_photos p
    WHERE p.session_id = p_session_id
      AND p.chat_type = 'single'
      AND p.owner_id = v_user_id
      AND pg_catalog.left(p.storage_path, pg_catalog.char_length(v_user_id::text) + 1) <> v_user_id::text || '/'
  ) THEN
    RAISE EXCEPTION 'chat_storage_path_owner_mismatch' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.chat_storage_deletion_jobs (
    deletion_job_id, bucket_id, object_path, resource_type, resource_id, owner_id
  )
  SELECT
    v_job_id, 'personax-memory-photos', p.storage_path,
    'single_session', p_session_id, v_user_id
  FROM public.chat_memory_photos p
  WHERE p.session_id = p_session_id
    AND p.chat_type = 'single'
    AND p.owner_id = v_user_id
  ON CONFLICT (bucket_id, object_path) DO NOTHING;

  IF EXISTS (
    SELECT 1
    FROM public.chat_storage_deletion_jobs sj
    JOIN public.chat_memory_photos p ON p.storage_path = sj.object_path
    WHERE p.session_id = p_session_id
      AND p.chat_type = 'single'
      AND p.owner_id = v_user_id
      AND (sj.owner_id <> v_user_id OR sj.deletion_job_id <> v_job_id)
  ) THEN
    RAISE EXCEPTION 'chat_storage_deletion_job_conflict' USING ERRCODE = '40001';
  END IF;

  PERFORM private.snapshot_chat_deletion_character_turn_stats(
    'single_session', p_session_id, v_user_id
  );

  UPDATE public.chat_sessions s
  SET deleted_at = COALESCE(s.deleted_at, v_deleted_at),
      updated_at = pg_catalog.statement_timestamp()
  WHERE s.id = p_session_id
    AND s.user_id = v_user_id;

  RETURN QUERY SELECT NULL::text WHERE false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_chat_group_with_related_data(p_group_id uuid)
RETURNS TABLE(storage_path text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_owner_id uuid;
  v_deleted_at timestamptz;
  v_job_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests r
    WHERE r.user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  SELECT g.owner_id, g.deleted_at
    INTO v_owner_id, v_deleted_at
  FROM public.chat_groups g
  WHERE g.id = p_group_id
  FOR UPDATE;

  IF NOT FOUND OR v_owner_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'group_not_found_or_not_owned' USING ERRCODE = '42501';
  END IF;

  v_deleted_at := COALESCE(v_deleted_at, pg_catalog.statement_timestamp());

  INSERT INTO public.chat_deletion_jobs (
    resource_type, resource_id, owner_id, deleted_at, purge_after, status
  )
  VALUES (
    'group', p_group_id, v_user_id, v_deleted_at,
    v_deleted_at + interval '30 days', 'queued'
  )
  ON CONFLICT (resource_type, resource_id) DO NOTHING;

  SELECT j.id
    INTO v_job_id
  FROM public.chat_deletion_jobs j
  WHERE j.resource_type = 'group'
    AND j.resource_id = p_group_id
    AND j.owner_id = v_user_id
    AND j.deleted_at = v_deleted_at
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'chat_deletion_job_conflict' USING ERRCODE = '40001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.chat_memory_photos p
    WHERE p.group_id = p_group_id
      AND p.chat_type = 'group'
      AND p.owner_id = v_user_id
      AND pg_catalog.left(p.storage_path, pg_catalog.char_length(v_user_id::text) + 1) <> v_user_id::text || '/'
  ) THEN
    RAISE EXCEPTION 'chat_storage_path_owner_mismatch' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.chat_storage_deletion_jobs (
    deletion_job_id, bucket_id, object_path, resource_type, resource_id, owner_id
  )
  SELECT
    v_job_id, 'personax-memory-photos', p.storage_path,
    'group', p_group_id, v_user_id
  FROM public.chat_memory_photos p
  WHERE p.group_id = p_group_id
    AND p.chat_type = 'group'
    AND p.owner_id = v_user_id
  ON CONFLICT (bucket_id, object_path) DO NOTHING;

  IF EXISTS (
    SELECT 1
    FROM public.chat_storage_deletion_jobs sj
    JOIN public.chat_memory_photos p ON p.storage_path = sj.object_path
    WHERE p.group_id = p_group_id
      AND p.chat_type = 'group'
      AND p.owner_id = v_user_id
      AND (sj.owner_id <> v_user_id OR sj.deletion_job_id <> v_job_id)
  ) THEN
    RAISE EXCEPTION 'chat_storage_deletion_job_conflict' USING ERRCODE = '40001';
  END IF;

  PERFORM private.snapshot_chat_deletion_character_turn_stats(
    'group', p_group_id, v_user_id
  );

  UPDATE public.chat_groups g
  SET deleted_at = COALESCE(g.deleted_at, v_deleted_at),
      updated_at = pg_catalog.statement_timestamp()
  WHERE g.id = p_group_id
    AND g.owner_id = v_user_id;

  RETURN QUERY SELECT NULL::text WHERE false;
END;
$function$;

-- Purge worker: add an idempotent last-chance snapshot before content is erased.
CREATE OR REPLACE FUNCTION public.purge_chat_deletion_job(p_job_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_job public.chat_deletion_jobs%ROWTYPE;
  v_owner_id uuid;
  v_parent_deleted_at timestamptz;
  v_parent_found boolean := false;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_job_id IS NULL THEN
    RAISE EXCEPTION 'job_id_required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_job FROM public.chat_deletion_jobs WHERE id = p_job_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'chat_deletion_job_not_found'; END IF;
  IF v_job.status = 'completed' THEN RETURN true; END IF;
  IF v_job.purge_after > pg_catalog.clock_timestamp() THEN
    RAISE EXCEPTION 'chat_deletion_not_due';
  END IF;

  IF v_job.resource_type = 'single_session' THEN
    SELECT s.user_id, s.deleted_at
      INTO v_owner_id, v_parent_deleted_at
    FROM public.chat_sessions s
    WHERE s.id = v_job.resource_id
    FOR UPDATE;
    v_parent_found := FOUND;
  ELSIF v_job.resource_type = 'group' THEN
    SELECT g.owner_id, g.deleted_at
      INTO v_owner_id, v_parent_deleted_at
    FROM public.chat_groups g
    WHERE g.id = v_job.resource_id
    FOR UPDATE;
    v_parent_found := FOUND;
  ELSE
    RAISE EXCEPTION 'unsupported_chat_resource_type';
  END IF;

  SELECT * INTO v_job FROM public.chat_deletion_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'chat_deletion_job_not_found'; END IF;
  IF v_job.status = 'completed' THEN RETURN true; END IF;
  IF v_job.status <> 'processing'
     OR v_job.lease_until IS NULL
     OR v_job.lease_until <= pg_catalog.clock_timestamp() THEN
    RAISE EXCEPTION 'chat_deletion_job_lease_not_owned';
  END IF;

  IF v_parent_found THEN
    IF v_owner_id IS DISTINCT FROM v_job.owner_id
       OR v_parent_deleted_at IS DISTINCT FROM v_job.deleted_at THEN
      RAISE EXCEPTION 'chat_deletion_parent_mismatch';
    END IF;

    PERFORM private.snapshot_chat_deletion_character_turn_stats(
      v_job.resource_type, v_job.resource_id, v_job.owner_id
    );

    PERFORM pg_catalog.set_config('app.chat_purge_worker', 'on', true);

    IF v_job.resource_type = 'single_session' THEN
      DELETE FROM public.chat_message_versions v
      WHERE v.message_id IN (
        SELECT m.id FROM public.chat_messages m WHERE m.session_id = v_job.resource_id
      );
      UPDATE public.chat_messages m
      SET content = '', deleted_at = COALESCE(m.deleted_at, v_job.deleted_at)
      WHERE m.session_id = v_job.resource_id;
      UPDATE public.ai_generation_records
      SET original_content = ''
      WHERE session_id = v_job.resource_id AND user_id = v_job.owner_id;
      UPDATE public.encounter_session_turns
      SET evaluation = '{}'::jsonb
      WHERE session_id = v_job.resource_id;
      UPDATE public.encounter_session_lifecycle
      SET schedule_snapshot = '{}'::jsonb,
          settlement_result = '{}'::jsonb,
          updated_at = pg_catalog.clock_timestamp()
      WHERE session_id = v_job.resource_id;
      DELETE FROM public.encounter_session_evaluation_jobs
      WHERE session_id = v_job.resource_id;
      UPDATE public.encounter_turn_interaction_receipts r
      SET diary_id = NULL
      FROM public.chat_turn_charges c
      WHERE c.turn_id = r.turn_id
        AND c.session_id = v_job.resource_id
        AND r.diary_id IS NOT NULL;
      DELETE FROM public.encounter_diary d
      WHERE d.user_id = v_job.owner_id
        AND d.metadata->>'session_id' = v_job.resource_id::text;
      UPDATE public.story_relationship_batches
      SET summary = NULL, evaluation = '{}'::jsonb
      WHERE session_id = v_job.resource_id;
      UPDATE public.story_relationship_states
      SET imported_memories = '[]'::jsonb, updated_at = pg_catalog.clock_timestamp()
      WHERE session_id = v_job.resource_id;
      DELETE FROM public.chat_memory_photos
      WHERE session_id = v_job.resource_id AND owner_id = v_job.owner_id;
      UPDATE public.chat_sessions
      SET session_data = '{}'::jsonb,
          character_snapshot = '{}'::jsonb,
          updated_at = pg_catalog.clock_timestamp()
      WHERE id = v_job.resource_id AND user_id = v_job.owner_id;
    ELSE
      UPDATE public.chat_groups
      SET background_mode = 'none',
          background_memory_photo_id = NULL,
          name = '已刪除對話',
          world_background = '',
          player_name = '',
          player_persona = '',
          world_character_id = NULL,
          pinned = false,
          updated_at = pg_catalog.clock_timestamp()
      WHERE id = v_job.resource_id AND owner_id = v_job.owner_id;
      DELETE FROM public.chat_group_messages WHERE group_id = v_job.resource_id;
      DELETE FROM public.chat_group_diary
      WHERE group_id = v_job.resource_id AND owner_id = v_job.owner_id;
      DELETE FROM public.chat_group_memory_photos
      WHERE group_id = v_job.resource_id AND owner_id = v_job.owner_id;
      DELETE FROM public.chat_memory_photos
      WHERE group_id = v_job.resource_id AND owner_id = v_job.owner_id;
      DELETE FROM public.chat_group_members WHERE group_id = v_job.resource_id;
      DELETE FROM public.chat_group_scenes WHERE group_id = v_job.resource_id;
      UPDATE public.chat_group_turns
      SET request_content = '[purged]'
      WHERE group_id = v_job.resource_id;
    END IF;
  END IF;

  UPDATE public.chat_deletion_jobs
  SET status = 'completed',
      next_attempt_at = NULL,
      lease_until = NULL,
      last_error_code = NULL,
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = p_job_id;

  RETURN true;
END;
$function$;

-- Current live count RPC definitions plus:
--   1) exclude messages under soft-deleted group parents,
--   2) add the immutable per-character archive aggregate.
CREATE OR REPLACE FUNCTION public.get_character_turn_counts(p_character_ids uuid[])
RETURNS TABLE(character_id uuid, turn_count bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  WITH requested AS (
    SELECT DISTINCT unnest(COALESCE(p_character_ids, ARRAY[]::uuid[])) AS character_id
  ),
  allowed AS (
    SELECT c.id AS character_id
    FROM public.characters AS c
    JOIN requested AS r ON r.character_id = c.id
    WHERE c.deleted_at IS NULL
      AND (
        c.author_id = (SELECT auth.uid())
        OR (
          c.visibility = 'public'
          AND (
            c.is_nsfw IS NOT TRUE
            OR ((SELECT auth.uid()) IS NOT NULL AND private.current_user_is_adult())
          )
        )
      )
  ),
  solo_counts AS (
    SELECT s.character_id, pg_catalog.count(m.id)::bigint AS turn_count
    FROM public.chat_sessions AS s
    LEFT JOIN public.chat_messages AS m
      ON m.session_id = s.id
     AND m.role = 'assistant'
     AND m.deleted_at IS NULL
    JOIN allowed AS a ON a.character_id = s.character_id
    WHERE s.deleted_at IS NULL
    GROUP BY s.character_id
  ),
  group_counts AS (
    SELECT gm.character_id, pg_catalog.count(gm.id)::bigint AS turn_count
    FROM public.chat_group_messages AS gm
    JOIN public.chat_groups AS g
      ON g.id = gm.group_id
     AND g.deleted_at IS NULL
    JOIN allowed AS a ON a.character_id = gm.character_id
    WHERE gm.speaker_type = 'character'
      AND gm.deleted_at IS NULL
    GROUP BY gm.character_id
  ),
  archived_counts AS (
    SELECT st.character_id, pg_catalog.sum(st.turn_count)::bigint AS turn_count
    FROM public.chat_deletion_character_turn_stats AS st
    JOIN allowed AS a ON a.character_id = st.character_id
    GROUP BY st.character_id
  )
  SELECT
    a.character_id,
    COALESCE(sc.turn_count, 0)
      + COALESCE(gc.turn_count, 0)
      + COALESCE(ac.turn_count, 0) AS turn_count
  FROM allowed AS a
  LEFT JOIN solo_counts AS sc ON sc.character_id = a.character_id
  LEFT JOIN group_counts AS gc ON gc.character_id = a.character_id
  LEFT JOIN archived_counts AS ac ON ac.character_id = a.character_id;
$function$;

CREATE OR REPLACE FUNCTION public.get_public_character_turn_count(p_character_id uuid)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT
    (
      SELECT pg_catalog.count(m.id)::bigint
      FROM public.chat_sessions AS s
      LEFT JOIN public.chat_messages AS m
        ON m.session_id = s.id
       AND m.role = 'assistant'
       AND m.deleted_at IS NULL
      WHERE s.character_id = c.id
        AND s.deleted_at IS NULL
    )
    +
    (
      SELECT pg_catalog.count(gm.id)::bigint
      FROM public.chat_group_messages AS gm
      JOIN public.chat_groups AS g
        ON g.id = gm.group_id
       AND g.deleted_at IS NULL
      WHERE gm.character_id = c.id
        AND gm.speaker_type = 'character'
        AND gm.deleted_at IS NULL
    )
    +
    (
      SELECT COALESCE(pg_catalog.sum(st.turn_count), 0)::bigint
      FROM public.chat_deletion_character_turn_stats AS st
      WHERE st.character_id = c.id
    )
  FROM public.characters AS c
  WHERE c.id = p_character_id
    AND c.visibility = 'public'
    AND c.deleted_at IS NULL
    AND (
      c.is_nsfw IS NOT TRUE
      OR ((SELECT auth.uid()) IS NOT NULL AND private.current_user_is_adult())
    );
$function$;

-- Preserve the current intended grants. Functions are created by postgres in
-- the migration context; verify owner/search_path/ACL after local replay.
REVOKE ALL ON FUNCTION public.delete_chat_session_content(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_chat_group_with_related_data(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_chat_session_content(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_chat_group_with_related_data(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.purge_chat_deletion_job(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_chat_deletion_job(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.get_character_turn_counts(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_public_character_turn_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_character_turn_counts(uuid[]) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_public_character_turn_count(uuid) TO anon, authenticated, service_role;

-- Required local regression tests before this draft can become a migration:
-- A. Active single session: assistant message count is unchanged.
-- B. Deleted single session: count is represented by exactly one archive snapshot.
-- C. Active group: each character's assistant messages remain counted.
-- D. Deleted parent group: raw child messages are excluded and archive counts
--    preserve each character's pre-delete total.
-- E. Deleted individual group message is not included in the snapshot.
-- F. Repeated delete RPC / worker retry does not duplicate archived counts.
-- G. Worker purge after 30 days removes transcript rows but archived counts remain.
-- H. Failed deletion RPC rolls back both snapshot and job/parent changes.
-- I. Concurrent writer vs delete: parent lock serializes; no message can be
--    inserted after the snapshot and before deleted_at is committed.
-- J. NSFW adult gate, owner-private access, deleted-character exclusion, grants,
--    owner=postgres, SECURITY DEFINER and search_path='' are unchanged.
-- K. Four legacy deleted sessions without jobs are queued at original
--    deleted_at + 30 days; no chat photo objects are touched by this SQL.
-- L. No role except postgres-owned SECURITY DEFINER code can directly read or
--    write the aggregate table.
