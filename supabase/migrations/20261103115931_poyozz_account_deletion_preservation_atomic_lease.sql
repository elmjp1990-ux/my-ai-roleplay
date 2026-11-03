-- Generated with Supabase CLI v2.84.2 as:
-- 20261103115931_poyozz_account_deletion_preservation_atomic_lease.sql
-- Fresh incremental migration. Historical migration files and ledger are not rewritten.
-- Required earlier migrations in this PR release set (apply in version order):
--   20261103040547_poyozz_chat_deletion_privilege_hardening.sql
--   20261103090100_account_is_active_auth_user_existence_guard.sql
-- Read-only test-project ledger inspection on 2026-11-03 found neither prerequisite
-- applied yet; the ledger's latest version is 20261101110211. This migration assumes
-- both PR prerequisites have been applied first.
-- Validated against the disposable current-state schema fixture only; do not apply
-- to hosted Supabase without explicit approval.


-- ============================================================================
-- A. Cumulative chat-deletion turn statistics and durable character-use history
-- ============================================================================

-- Reviewed against read-only live test-project definitions on 2026-11-01.
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
-- The snapshot stores only source tombstone IDs, character IDs and counts; it does not retain player IDs or transcript content. The snapshot is written in the same transaction as the player delete RPC,
-- after the parent row has been locked and before deleted_at is set. All writer
-- paths must continue to lock the same parent row, so no post-snapshot writes
-- can slip in. The purge worker repeats the snapshot idempotently as a safety
-- net for older queued jobs.

CREATE TABLE IF NOT EXISTS public.chat_deletion_character_turn_stats (
  resource_type text NOT NULL
    CHECK (resource_type IN ('single_session', 'group')),
  resource_id uuid NOT NULL,
  character_id uuid NOT NULL,  -- no player/account identifier is retained in the aggregate
  turn_count bigint NOT NULL CHECK (turn_count > 0),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT chat_deletion_character_turn_stats_resource_character_key
    UNIQUE (resource_type, resource_id, character_id)
);

CREATE INDEX IF NOT EXISTS chat_deletion_character_turn_stats_character_idx
  ON public.chat_deletion_character_turn_stats (character_id);

-- Independent character-use tombstones: unlike turn-count aggregates, these rows
-- record every character attached to a deleted chat, including members who never
-- produced an assistant reply. They deliberately have NO FK to chat parents or
-- characters, so the link survives day-30 purge and a later character hard-delete.
CREATE TABLE IF NOT EXISTS public.chat_deletion_character_history (
  resource_type text NOT NULL
    CHECK (resource_type IN ('single_session', 'group')),
  resource_id uuid NOT NULL,
  character_id uuid NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT chat_deletion_character_history_resource_character_key
    UNIQUE (resource_type, resource_id, character_id)
);

CREATE INDEX IF NOT EXISTS chat_deletion_character_history_character_idx
  ON public.chat_deletion_character_history (character_id);

ALTER TABLE public.chat_deletion_character_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.chat_deletion_character_history
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE public.chat_deletion_character_history IS
  'Minimal immutable character-use tombstones retained after chat purge; stores no player ID or transcript content and has no FK to parents or characters.';

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
    INSERT INTO public.chat_deletion_character_history (
      resource_type, resource_id, character_id
    )
    SELECT 'single_session', s.id, s.character_id
    FROM public.chat_sessions AS s
    WHERE s.id = p_resource_id
      AND s.user_id = p_owner_id
      AND s.character_id IS NOT NULL
    ON CONFLICT (resource_type, resource_id, character_id) DO NOTHING;

    INSERT INTO public.chat_deletion_character_turn_stats (
      resource_type, resource_id, character_id, turn_count
    )
    SELECT
      'single_session',
      s.id,
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
    INSERT INTO public.chat_deletion_character_history (
      resource_type, resource_id, character_id
    )
    SELECT 'group', p_resource_id, source.character_id
    FROM (
      SELECT gm.character_id
      FROM public.chat_group_members AS gm
      JOIN public.chat_groups AS g ON g.id = gm.group_id
      WHERE g.id = p_resource_id AND g.owner_id = p_owner_id
      UNION
      SELECT gm.character_id
      FROM public.chat_group_messages AS gm
      JOIN public.chat_groups AS g ON g.id = gm.group_id
      WHERE g.id = p_resource_id AND g.owner_id = p_owner_id
      UNION
      SELECT g.world_character_id AS character_id
      FROM public.chat_groups AS g
      WHERE g.id = p_resource_id AND g.owner_id = p_owner_id
    ) AS source
    WHERE source.character_id IS NOT NULL
    ON CONFLICT (resource_type, resource_id, character_id) DO NOTHING;

    INSERT INTO public.chat_deletion_character_turn_stats (
      resource_type, resource_id, character_id, turn_count
    )
    SELECT
      'group',
      g.id,
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

  -- Fail closed if a pre-existing aggregate is incomplete or stale. ON CONFLICT
  -- DO NOTHING is safe only when the first snapshot is complete and immutable.
  IF p_resource_type = 'single_session' AND EXISTS (
    SELECT 1
    FROM public.chat_sessions AS s
    CROSS JOIN LATERAL (
      SELECT pg_catalog.count(m.id)::bigint AS expected_count
      FROM public.chat_messages AS m
      WHERE m.session_id = s.id
        AND m.role = 'assistant'
        AND m.deleted_at IS NULL
    ) AS expected
    LEFT JOIN public.chat_deletion_character_turn_stats AS archived
      ON archived.resource_type = 'single_session'
     AND archived.resource_id = s.id
     AND archived.character_id = s.character_id
    WHERE s.id = p_resource_id
      AND s.user_id = p_owner_id
      AND (
        (expected.expected_count > 0 AND archived.character_id IS NULL)
        OR COALESCE(archived.turn_count, 0) <> expected.expected_count
      )
  ) THEN
    RAISE EXCEPTION 'chat_deletion_turn_snapshot_incomplete' USING ERRCODE = '23514';
  ELSIF p_resource_type = 'group' AND EXISTS (
    WITH expected AS (
      SELECT gm.character_id, pg_catalog.count(gm.id)::bigint AS turn_count
      FROM public.chat_group_messages AS gm
      WHERE gm.group_id = p_resource_id
        AND gm.speaker_type = 'character'
        AND gm.deleted_at IS NULL
        AND gm.character_id IS NOT NULL
      GROUP BY gm.character_id
    ), archived AS (
      SELECT s.character_id, s.turn_count
      FROM public.chat_deletion_character_turn_stats AS s
      WHERE s.resource_type = 'group'
        AND s.resource_id = p_resource_id
    )
    SELECT 1
    FROM expected
    FULL OUTER JOIN archived USING (character_id)
    WHERE COALESCE(expected.turn_count, 0)
       <> COALESCE(archived.turn_count, 0)
  ) THEN
    RAISE EXCEPTION 'chat_deletion_turn_snapshot_incomplete' USING ERRCODE = '23514';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION private.snapshot_chat_deletion_character_turn_stats(text, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

-- Account deletion bypasses the ordinary single/group chat soft-delete RPCs:
-- Auth FK cascades remove chat_sessions and chat_groups directly. Capture the
-- same minimal character-use tombstones and assistant-turn aggregates before
-- prepare_account_deletion permits Auth deletion. No transcript text or player
-- identifier is written to these aggregate tables.
CREATE OR REPLACE FUNCTION private.snapshot_account_chat_character_history(
  p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_session record;
  v_group record;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'account_chat_history_owner_required' USING ERRCODE = '22023';
  END IF;

  -- Match the parent-first writer-lock protocol used by chat deletion. Stable
  -- ordering prevents two maintenance paths from acquiring these locks in
  -- inconsistent order.
  PERFORM 1
  FROM public.chat_sessions AS s
  WHERE s.user_id = p_user_id
  ORDER BY s.id
  FOR UPDATE;

  PERFORM 1
  FROM public.chat_groups AS g
  WHERE g.owner_id = p_user_id
  ORDER BY g.id
  FOR UPDATE;

  FOR v_session IN
    SELECT s.id, s.character_id
    FROM public.chat_sessions AS s
    WHERE s.user_id = p_user_id
    ORDER BY s.id
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.chat_deletion_jobs AS j
      WHERE j.resource_type = 'single_session'
        AND j.resource_id = v_session.id
        AND j.status = 'completed'
    ) THEN
      -- A completed 30-day purge has already removed/blanked transcript rows.
      -- Never recompute from the now-empty transcript; require its tombstone.
      IF v_session.character_id IS NOT NULL
         AND NOT EXISTS (
           SELECT 1
           FROM public.chat_deletion_character_history AS h
           WHERE h.resource_type = 'single_session'
             AND h.resource_id = v_session.id
             AND h.character_id = v_session.character_id
         ) THEN
        RAISE EXCEPTION 'account_chat_history_tombstone_missing'
          USING ERRCODE = '23514';
      END IF;
    ELSE
      PERFORM private.snapshot_chat_deletion_character_turn_stats(
        'single_session', v_session.id, p_user_id
      );
    END IF;
  END LOOP;

  FOR v_group IN
    SELECT g.id, g.world_character_id
    FROM public.chat_groups AS g
    WHERE g.owner_id = p_user_id
    ORDER BY g.id
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.chat_deletion_jobs AS j
      WHERE j.resource_type = 'group'
        AND j.resource_id = v_group.id
        AND j.status = 'completed'
    ) THEN
      -- Group purge removes member/message rows. The durable history table is
      -- then the only authoritative record of members that never replied.
      IF NOT EXISTS (
        SELECT 1
        FROM public.chat_deletion_character_history AS h
        WHERE h.resource_type = 'group'
          AND h.resource_id = v_group.id
      ) THEN
        RAISE EXCEPTION 'account_group_history_tombstone_missing'
          USING ERRCODE = '23514';
      END IF;
      IF v_group.world_character_id IS NOT NULL
         AND NOT EXISTS (
           SELECT 1
           FROM public.chat_deletion_character_history AS h
           WHERE h.resource_type = 'group'
             AND h.resource_id = v_group.id
             AND h.character_id = v_group.world_character_id
         ) THEN
        RAISE EXCEPTION 'account_group_world_character_tombstone_missing'
          USING ERRCODE = '23514';
      END IF;
      IF EXISTS (
        SELECT 1
        FROM public.chat_deletion_character_turn_stats AS st
        LEFT JOIN public.chat_deletion_character_history AS h
          ON h.resource_type = st.resource_type
         AND h.resource_id = st.resource_id
         AND h.character_id = st.character_id
        WHERE st.resource_type = 'group'
          AND st.resource_id = v_group.id
          AND h.character_id IS NULL
      ) THEN
        RAISE EXCEPTION 'account_group_turn_stats_tombstone_mismatch'
          USING ERRCODE = '23514';
      END IF;
    ELSE
      PERFORM private.snapshot_chat_deletion_character_turn_stats(
        'group', v_group.id, p_user_id
      );
    END IF;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION private.snapshot_account_chat_character_history(uuid)
  FROM PUBLIC, anon, authenticated, service_role;

-- Backfill any already soft-deleted parents before the new count RPCs start
-- including archived statistics. Idempotent by the resource/character key.
INSERT INTO public.chat_deletion_character_turn_stats (
  resource_type, resource_id, character_id, turn_count
)
SELECT
  'single_session',
  s.id,
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
  resource_type, resource_id, character_id, turn_count
)
SELECT
  'group',
  g.id,
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

-- Backfill immutable character-use tombstones for existing deleted parents
-- before day-30 purge removes group membership/message rows. Existing turn
-- aggregates are also a source for groups whose member rows were already purged.
INSERT INTO public.chat_deletion_character_history (
  resource_type, resource_id, character_id
)
SELECT 'single_session', s.id, s.character_id
FROM public.chat_sessions AS s
WHERE s.deleted_at IS NOT NULL
  AND s.character_id IS NOT NULL
ON CONFLICT (resource_type, resource_id, character_id) DO NOTHING;

INSERT INTO public.chat_deletion_character_history (
  resource_type, resource_id, character_id
)
SELECT 'group', g.id, source.character_id
FROM public.chat_groups AS g
CROSS JOIN LATERAL (
  SELECT gm.character_id
  FROM public.chat_group_members AS gm
  WHERE gm.group_id = g.id
  UNION
  SELECT gm.character_id
  FROM public.chat_group_messages AS gm
  WHERE gm.group_id = g.id
  UNION
  SELECT g.world_character_id AS character_id
  UNION
  SELECT st.character_id
  FROM public.chat_deletion_character_turn_stats AS st
  WHERE st.resource_type = 'group' AND st.resource_id = g.id
) AS source
WHERE g.deleted_at IS NOT NULL
  AND source.character_id IS NOT NULL
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

-- Fail closed if an existing resource job conflicts with the legacy parent.
DO $block$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.chat_sessions AS s
    JOIN public.chat_deletion_jobs AS j
      ON j.resource_type = 'single_session' AND j.resource_id = s.id
    WHERE s.deleted_at IS NOT NULL
      AND (j.owner_id IS DISTINCT FROM s.user_id OR j.deleted_at IS DISTINCT FROM s.deleted_at)
  ) OR EXISTS (
    SELECT 1
    FROM public.chat_groups AS g
    JOIN public.chat_deletion_jobs AS j
      ON j.resource_type = 'group' AND j.resource_id = g.id
    WHERE g.deleted_at IS NOT NULL
      AND (j.owner_id IS DISTINCT FROM g.owner_id OR j.deleted_at IS DISTINCT FROM g.deleted_at)
  ) THEN
    RAISE EXCEPTION 'chat_deletion_job_conflict';
  END IF;
END;
$block$;

-- Fail closed if a Storage path is already assigned to a different deletion job.
DO $block$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.chat_memory_photos AS p
    JOIN public.chat_deletion_jobs AS j
      ON ((p.chat_type = 'single' AND j.resource_type = 'single_session' AND j.resource_id = p.session_id)
       OR (p.chat_type = 'group' AND j.resource_type = 'group' AND j.resource_id = p.group_id))
    JOIN public.chat_storage_deletion_jobs AS sj
      ON sj.bucket_id = 'personax-memory-photos'
     AND sj.object_path = p.storage_path
    WHERE sj.owner_id IS DISTINCT FROM j.owner_id
       OR sj.deletion_job_id IS DISTINCT FROM j.id
  ) THEN
    RAISE EXCEPTION 'chat_storage_deletion_job_conflict';
  END IF;
END;
$block$;

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
--   1) read live messages only from active parents,
--   2) add immutable per-character snapshots for deleted parents.
-- IMPORTANT: deleting a chat must NOT reduce a character's historical total.
-- A deleted group's contribution moves from live child messages to this archive;
-- after day-30 transcript purge the same archived contribution remains counted.
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
    WHERE (
      -- Owners retain access to their own statistics even after soft-deleting
      -- a character. Public callers must never see deleted-character counts.
      c.author_id = (SELECT auth.uid())
      OR (
        c.deleted_at IS NULL
        AND c.visibility = 'public'
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
    WHERE (
      -- During account deletion, snapshots are committed before Auth FK
      -- cascades remove the author's own active chat parents. Until that
      -- cascade occurs, the live parent/message path remains authoritative;
      -- count the snapshot only after the parent is soft-deleted or absent.
      (st.resource_type = 'single_session' AND NOT EXISTS (
        SELECT 1 FROM public.chat_sessions AS s
        WHERE s.id = st.resource_id AND s.deleted_at IS NULL
      ))
      OR
      (st.resource_type = 'group' AND NOT EXISTS (
        SELECT 1 FROM public.chat_groups AS g
        WHERE g.id = st.resource_id AND g.deleted_at IS NULL
      ))
    )
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
        AND (
          (st.resource_type = 'single_session' AND NOT EXISTS (
            SELECT 1 FROM public.chat_sessions AS s
            WHERE s.id = st.resource_id AND s.deleted_at IS NULL
          ))
          OR
          (st.resource_type = 'group' AND NOT EXISTS (
            SELECT 1 FROM public.chat_groups AS g
            WHERE g.id = st.resource_id AND g.deleted_at IS NULL
          ))
        )
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

-- A. Active single session: assistant message count is unchanged.
-- B. Deleted single session: count is represented by exactly one archive snapshot.
-- C. Active group: each character's assistant messages remain counted.
-- D. Deleted parent group: raw child messages are excluded from the live path,
--    but each character's pre-delete contribution remains in the aggregate via
--    exactly one archive row; deletion must not reduce the historical total.
-- D1. Verify both owner-visible and public aggregate RPCs still include the
--     deleted group's archived contribution during the 30-day grace period and
--     after transcript purge.
-- E. Deleted individual group message is not included in the snapshot.
-- F. Repeated delete RPC / worker retry does not duplicate archived counts.
-- G. Worker purge after 30 days removes transcript rows but archived counts remain;
--    re-running the worker cannot duplicate or erase the archived contribution.
-- H. Failed deletion RPC rolls back both snapshot and job/parent changes.
-- I. Concurrent writer vs delete: parent lock serializes; no message can be
--    inserted after the snapshot and before deleted_at is committed.
-- J. NSFW adult gate, owner-private access, deleted-character exclusion, grants,
--    owner=postgres, SECURITY DEFINER and search_path='' are unchanged.
-- K. Four legacy deleted sessions without jobs are queued at original
--    deleted_at + 30 days; no chat photo objects are touched by this SQL.
-- L. No role except postgres-owned SECURITY DEFINER code can directly read or
--    write the aggregate table.

-- ============================================================================
-- B. History-aware character deletion and private asset cleanup queue
-- ============================================================================

-- History-aware character deletion and private Storage cleanup queue.
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

-- ============================================================================
-- C. Parent-first character snapshot synchronization
-- ============================================================================

-- The same post-delete freeze must cover character soft deletion itself.
-- The existing soft_delete_character() also rewrites snapshots, so fixing only
-- sync_character_chat_snapshot() would leave a second SECURITY DEFINER bypass.
-- Merge the history-aware hard-delete path with parent locking for both
-- member and message references. The character row is locked first, followed
-- by active chat parents, matching sync_character_chat_snapshot's lock order.
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
    AND (
      EXISTS (
        SELECT 1
        FROM public.chat_group_members gm
        WHERE gm.group_id = g.id
          AND gm.character_id = p_character_id
      )
      OR EXISTS (
        SELECT 1
        FROM public.chat_group_messages msg
        WHERE msg.group_id = g.id
          AND msg.character_id = p_character_id
      )
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

-- authenticated race fixtures pass.
--
-- Defect confirmed in live test DB on 2026-11-02:
-- The current SECURITY DEFINER function updates chat_group_members and
-- chat_group_messages by character_id without locking the parent chat_groups
-- row and without excluding deleted groups. This permits metadata mutation
-- after chat deletion even though authenticated RLS blocks ordinary writes.
--
-- Lock the character row first (same order as soft_delete_character), then
-- lock active parents in deterministic order before updating their snapshots.
-- Deletion RPCs use the same parent-first lock, so a concurrent sync either
-- commits before deletion or waits and observes deleted_at after deletion.

CREATE OR REPLACE FUNCTION public.sync_character_chat_snapshot(p_character_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_author_id uuid;
  v_visibility text;
  v_first_published_at timestamptz;
  v_deleted_at timestamptz;
  v_parent_id uuid;
  v_count integer := 0;
  v_rows integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF NOT public.account_is_active() THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  SELECT c.author_id, c.visibility, c.first_published_at, c.deleted_at
    INTO v_author_id, v_visibility, v_first_published_at, v_deleted_at
  FROM public.characters c
  WHERE c.id = p_character_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Character not found.';
  END IF;
  IF v_author_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Not allowed to update this character snapshot.' USING ERRCODE = '42501';
  END IF;

  -- Single-chat parent locks first. A deleted session is intentionally frozen.
  FOR v_parent_id IN
    SELECT cs.id
    FROM public.chat_sessions cs
    WHERE cs.character_id = p_character_id
      AND cs.deleted_at IS NULL
    ORDER BY cs.id
    FOR UPDATE
  LOOP
    NULL;
  END LOOP;

  UPDATE public.chat_sessions cs
  SET character_snapshot = COALESCE(cs.character_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', v_visibility,
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    ),
    updated_at = pg_catalog.now()
  WHERE cs.character_id = p_character_id
    AND cs.deleted_at IS NULL;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_count := v_count + v_rows;

  -- Group parent locks are deterministic and acquired before child updates.
  FOR v_parent_id IN
    SELECT g.id
    FROM public.chat_groups g
    WHERE g.deleted_at IS NULL
      AND (
        EXISTS (
          SELECT 1 FROM public.chat_group_members gm
          WHERE gm.group_id = g.id AND gm.character_id = p_character_id
        )
        OR EXISTS (
          SELECT 1 FROM public.chat_group_messages msg
          WHERE msg.group_id = g.id AND msg.character_id = p_character_id
        )
      )
    ORDER BY g.id
    FOR UPDATE OF g
  LOOP
    NULL;
  END LOOP;

  UPDATE public.chat_group_members gm
  SET character_snapshot = COALESCE(gm.character_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', v_visibility,
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    )
  WHERE gm.character_id = p_character_id
    AND EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = gm.group_id AND g.deleted_at IS NULL
    );
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_count := v_count + v_rows;

  UPDATE public.chat_group_messages gm
  SET speaker_snapshot = COALESCE(gm.speaker_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', v_visibility,
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    )
  WHERE gm.character_id = p_character_id
    AND EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = gm.group_id AND g.deleted_at IS NULL
    );
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_count := v_count + v_rows;

  RETURN v_count;
END;
$function$;

-- 1. sync obtains parent lock first: snapshot update commits, then delete runs.
-- 2. delete obtains parent lock first: sync waits, then updates zero rows for
--    that deleted parent.
-- 3. Deleted parent members/messages remain byte-for-byte unchanged after sync.
-- 4. Active parent members/messages still receive the current character fields.
-- 5. Non-author, unauthenticated, and account-deletion-pending callers fail.
-- 6. Verify function owner, EXECUTE ACL, search_path, and SECURITY DEFINER
--    dependencies remain unchanged; no anon/PUBLIC execute path is introduced.

-- ============================================================================
-- D. Account character preservation and ownership detachment
-- ============================================================================

-- Account deletion must preserve every character and all of its child data/media.
-- Reconcile the full migration ledger and test this on a disposable local database first.
--
-- Source section is based on read-only catalog inspection from 2026-11-02.

-- 1) Durable, non-clickable creator attribution and explicit account archive marker.
ALTER TABLE public.characters
  ADD COLUMN IF NOT EXISTS creator_display_name text,
  ADD COLUMN IF NOT EXISTS account_archived_at timestamptz;

COMMENT ON COLUMN public.characters.creator_display_name IS
  'Plain-text historical creator attribution; not a profile link.';
-- Creator attribution is stored as plain text only; never as a profile link.
COMMENT ON COLUMN public.characters.account_archived_at IS
  'Set when the creator account is deleted; blocks all new sessions while preserving existing sessions.';

-- 2) Detach active ownership instead of cascading character content away.
-- Keep profiles.id -> auth.users(id) ON DELETE CASCADE unchanged.
ALTER TABLE public.characters ALTER COLUMN author_id DROP NOT NULL;
ALTER TABLE public.characters DROP CONSTRAINT IF EXISTS characters_author_id_fkey;
ALTER TABLE public.characters
  ADD CONSTRAINT characters_author_id_fkey
  FOREIGN KEY (author_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.character_private_info ALTER COLUMN author_id DROP NOT NULL;
ALTER TABLE public.character_private_info DROP CONSTRAINT IF EXISTS character_private_info_author_id_fkey;
ALTER TABLE public.character_private_info
  ADD CONSTRAINT character_private_info_author_id_fkey
  FOREIGN KEY (author_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.character_illustrations ALTER COLUMN author_id DROP NOT NULL;
ALTER TABLE public.character_illustrations DROP CONSTRAINT IF EXISTS character_illustrations_author_id_fkey;
ALTER TABLE public.character_illustrations
  ADD CONSTRAINT character_illustrations_author_id_fkey
  FOREIGN KEY (author_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

-- This table references auth.users directly, not profiles.
ALTER TABLE public.character_schedule_descriptions ALTER COLUMN author_id DROP NOT NULL;
ALTER TABLE public.character_schedule_descriptions
  DROP CONSTRAINT IF EXISTS character_schedule_descriptions_author_id_fkey;
ALTER TABLE public.character_schedule_descriptions
  ADD CONSTRAINT character_schedule_descriptions_author_id_fkey
  FOREIGN KEY (author_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- 3) Narrow existing-session authorization. This deliberately ignores current
-- character visibility/deleted_at: existing session owners may continue and load
-- the character's exact media; users without a prior session get false.
CREATE OR REPLACE FUNCTION private.user_has_existing_character_session(
  p_character_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  -- Existing-session access requires a live, active account. Pair this with
  -- account_is_active()'s auth.users existence guard so an unexpired JWT from
  -- a deleted account cannot continue reading retained character assets.
  SELECT auth.uid() IS NOT NULL
    AND public.account_is_active() IS TRUE
    AND p_character_id IS NOT NULL
    AND (
      EXISTS (
        SELECT 1
        FROM public.chat_sessions AS s
        WHERE s.character_id = p_character_id
          AND s.user_id = auth.uid()
          AND s.deleted_at IS NULL
      )
      OR EXISTS (
        SELECT 1
        FROM public.chat_group_members AS gm
        JOIN public.chat_groups AS g
          ON g.id = gm.group_id
        WHERE gm.character_id = p_character_id
          AND g.owner_id = auth.uid()
          -- archived_at only hides a group from the active list; it is not deletion.
          -- An archived group remains an existing conversation and retains access.
          AND g.deleted_at IS NULL
      )
    );
$function$;

REVOKE ALL ON FUNCTION private.user_has_existing_character_session(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.user_has_existing_character_session(uuid)
  TO authenticated;

-- 4) Storage policy helper: exact path must be referenced by the character row
-- or illustration metadata, and the caller must own an existing undeleted chat/group.
CREATE OR REPLACE FUNCTION private.can_read_character_asset(
  p_bucket_id text,
  p_object_name text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT auth.uid() IS NOT NULL
    AND CASE p_bucket_id
      WHEN 'character-illustrations' THEN EXISTS (
        SELECT 1
        FROM public.character_illustrations AS ci
        WHERE ci.storage_path = p_object_name
          AND private.user_has_existing_character_session(ci.character_id)
      )
      WHEN 'character-avatar-videos' THEN EXISTS (
        SELECT 1
        FROM public.characters AS c
        WHERE c.avatar_video_path = p_object_name
          AND private.user_has_existing_character_session(c.id)
      )
      ELSE false
    END;
$function$;

REVOKE ALL ON FUNCTION private.can_read_character_asset(text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_read_character_asset(text, text)
  TO authenticated;

-- Existing client-side illustration cleanup can already have a job in memory
-- when account archival detaches author_id and removes pending queue rows. The
-- old direct metadata SELECT filtered by author_id then falsely saw no reference
-- and could remove a still-live asset. This caller-bound RPC is fail-closed:
-- inactive/deleted/revoked sessions and any remaining reference all return false.
CREATE OR REPLACE FUNCTION public.can_process_character_illustration_cleanup(
  p_job_id uuid,
  p_user_id uuid,
  p_storage_path text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_session_id uuid;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'not_allowed_to_process_character_asset_cleanup'
      USING ERRCODE = '42501';
  END IF;

  IF NOT public.account_is_active() THEN
    RETURN false;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.character_illustration_cleanup_jobs AS j
    WHERE j.id = p_job_id
      AND j.author_id = p_user_id
      AND j.storage_path = p_storage_path
  ) THEN
    RETURN false;
  END IF;

  v_session_id := NULLIF(auth.jwt() ->> 'session_id', '')::uuid;
  IF v_session_id IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM auth.sessions AS s
       WHERE s.id = v_session_id AND s.user_id = p_user_id
     )
     OR NOT EXISTS (
       SELECT 1 FROM auth.users AS u
       WHERE u.id = p_user_id
     ) THEN
    RETURN false;
  END IF;

  IF p_storage_path IS NULL
     OR p_storage_path !~ (
       '^' || p_user_id::text ||
       '/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' ||
       '/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$'
     ) THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.character_illustrations AS ci
    WHERE ci.storage_path = p_storage_path
  ) OR EXISTS (
    SELECT 1 FROM public.characters AS c
    WHERE c.avatar_video_path = p_storage_path
  ) THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.can_process_character_illustration_cleanup(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_process_character_illustration_cleanup(uuid, uuid, text)
  TO authenticated;

-- Existing public/author policies remain. These additional SELECT policies are
-- authenticated-only and do not allow upload, update, or delete.
DROP POLICY IF EXISTS "Existing session owners can read character illustration metadata"
  ON public.character_illustrations;
CREATE POLICY "Existing session owners can read character illustration metadata"
  ON public.character_illustrations
  FOR SELECT TO authenticated
  USING (private.user_has_existing_character_session(character_id));

DROP POLICY IF EXISTS "Existing session owners can read archived character assets"
  ON storage.objects;
CREATE POLICY "Existing session owners can read archived character assets"
  ON storage.objects
  FOR SELECT TO authenticated
  USING (private.can_read_character_asset(bucket_id, name));

-- 5) Explicitly exclude account-archived characters from caller-side new-session
-- eligibility helpers as well as the INSERT triggers below.
CREATE OR REPLACE FUNCTION public.character_can_start_chat(p_character_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.characters AS c
    WHERE c.id = p_character_id
      AND c.account_archived_at IS NULL
      AND c.deleted_at IS NULL
      AND (
        c.author_id = (SELECT auth.uid())
        OR (c.visibility = 'public' AND c.review_status = 'approved')
      )
  );
$function$;

CREATE OR REPLACE FUNCTION public.can_open_encounter_session(p_character_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.characters AS c
    WHERE c.id = p_character_id
      AND c.account_archived_at IS NULL
      AND c.visibility = 'public'
      AND c.deleted_at IS NULL
      AND c.review_status = 'approved'
      AND c.rights_confirmed IS TRUE
      AND (
        c.is_nsfw IS NOT TRUE
        OR (
          auth.uid() IS NOT NULL
          AND private.current_user_is_adult()
        )
      )
  );
$function$;

-- City/map schedule discovery must also hide account-archived characters,
-- while public character discovery itself continues to return public works.
CREATE OR REPLACE FUNCTION public.get_encounter_character_schedule(p_character_id uuid)
RETURNS TABLE(
  weekday smallint,
  day_type text,
  start_time time without time zone,
  end_time time without time zone,
  location_key text,
  activity text,
  priority smallint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT
    s.weekday, s.day_type, s.start_time, s.end_time,
    s.location_key, s.activity, s.priority
  FROM public.characters AS c
  JOIN public.character_schedules AS s ON s.character_id = c.id
  WHERE c.id = p_character_id
    AND c.account_archived_at IS NULL
    AND c.visibility = 'public'
    AND c.deleted_at IS NULL
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND s.is_active IS TRUE
    AND (
      c.is_nsfw IS NOT TRUE
      OR (
        (SELECT auth.uid()) IS NOT NULL
        AND private.current_user_is_adult()
      )
    )
  ORDER BY s.priority DESC, s.weekday NULLS FIRST, s.start_time;
$function$;

-- CREATE OR REPLACE preserves the currently audited function ownership and
-- EXECUTE ACLs; verify both again after local replay.

-- 6) Service-only account archive helper.
-- The helper is called internally by the SECURITY DEFINER prepare RPC; do not
-- broaden schema USAGE on the private schema just for this internal call.

-- Call from the final prepare_account_deletion() transaction only after the
-- request is due and account writes are frozen, but BEFORE deleting auth.users.
-- It preserves all characters (including private/unpublished) and all child rows.
CREATE OR REPLACE FUNCTION private.archive_account_characters(
  p_user_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_nickname text;
  v_archived_at timestamptz := pg_catalog.statement_timestamp();
  v_character_count integer := 0;
BEGIN
  -- Trust the signed JWT role claim; auth.role() is deprecated by Supabase.
  IF (auth.jwt() ->> 'role') IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'target_user_required' USING ERRCODE = '22023';
  END IF;

  SELECT p.nickname
    INTO v_nickname
  FROM public.profiles AS p
  WHERE p.id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile_not_found_before_character_archive' USING ERRCODE = 'P0002';
  END IF;

  -- Lock all characters first; no publication-state filter by design.
  PERFORM 1
  FROM public.characters AS c
  WHERE c.author_id = p_user_id
  FOR UPDATE;

  -- Lock child rows whose data is retained but not otherwise updated below.
  -- This serializes in-flight owner writes against the archival transaction;
  -- after commit, the parent author_id is NULL and the owner RLS predicates fail.
  PERFORM 1
  FROM public.character_schedules AS cs
  JOIN public.characters AS c ON c.id = cs.character_id
  WHERE c.author_id = p_user_id
  FOR UPDATE OF cs;

  PERFORM 1
  FROM public.character_stories AS st
  JOIN public.characters AS c ON c.id = st.character_id
  WHERE c.author_id = p_user_id
  FOR UPDATE OF st;

  -- Preserve creator attribution in every existing single-chat snapshot.
  WITH owned AS (
    SELECT c.id,
      COALESCE(NULLIF(c.creator_display_name, ''),
               NULLIF(v_nickname, ''),
               '原作者') AS creator_name,
      c.visibility AS current_visibility
    FROM public.characters AS c
    WHERE c.author_id = p_user_id
  )
  UPDATE public.chat_sessions AS s
  SET character_snapshot =
      COALESCE(s.character_snapshot, '{}'::jsonb) ||
      jsonb_build_object(
        'authorId', NULL,
        'creatorDisplayName', owned.creator_name,
        'creatorProfileAvailable', false,
        'characterStatus', 'offline',
        'isOnline', false,
        'visibility', owned.current_visibility,
        'accountArchivedAt', v_archived_at
      ),
      updated_at = v_archived_at
  FROM owned
  WHERE s.character_id = owned.id
    -- The deleting account's own sessions are removed by the later Auth FK
    -- cascade. They were already snapshotted above for aggregate character
    -- counts, so do not UPDATE them while account deletion is pending: the
    -- pending-account guard intentionally rejects writes to those sessions.
    -- Only other players' retained sessions need the offline/creator snapshot.
    AND s.user_id <> p_user_id;

  -- Preserve creator attribution in group member snapshots.
  WITH owned AS (
    SELECT c.id,
      COALESCE(NULLIF(c.creator_display_name, ''),
               NULLIF(v_nickname, ''),
               '原作者') AS creator_name,
      c.visibility AS current_visibility
    FROM public.characters AS c
    WHERE c.author_id = p_user_id
  )
  UPDATE public.chat_group_members AS gm
  SET character_snapshot =
      COALESCE(gm.character_snapshot, '{}'::jsonb) ||
      jsonb_build_object(
        'authorId', NULL,
        'creatorDisplayName', owned.creator_name,
        'creatorProfileAvailable', false,
        'characterStatus', 'offline',
        'isOnline', false,
        'visibility', owned.current_visibility,
        'accountArchivedAt', v_archived_at
      )
  FROM owned
  WHERE gm.character_id = owned.id;

  -- Preserve creator attribution in group speaker snapshots.
  WITH owned AS (
    SELECT c.id,
      COALESCE(NULLIF(c.creator_display_name, ''),
               NULLIF(v_nickname, ''),
               '原作者') AS creator_name,
      c.visibility AS current_visibility
    FROM public.characters AS c
    WHERE c.author_id = p_user_id
  )
  UPDATE public.chat_group_messages AS gm
  SET speaker_snapshot =
      COALESCE(gm.speaker_snapshot, '{}'::jsonb) ||
      jsonb_build_object(
        'authorId', NULL,
        'creatorDisplayName', owned.creator_name,
        'creatorProfileAvailable', false,
        'characterStatus', 'offline',
        'isOnline', false,
        'visibility', owned.current_visibility,
        'accountArchivedAt', v_archived_at
      )
  FROM owned
  WHERE gm.character_id = owned.id
    AND gm.speaker_type = 'character';

  -- Detach author IDs from character-owned children before profile/Auth deletion.
  UPDATE public.character_private_info
  SET author_id = NULL
  WHERE author_id = p_user_id;

  UPDATE public.character_illustrations
  SET author_id = NULL
  WHERE author_id = p_user_id;

  UPDATE public.character_schedule_descriptions
  SET author_id = NULL
  WHERE author_id = p_user_id;

  -- Cancel pending cleanup queue records only. Never delete Storage objects here.
  DELETE FROM public.character_illustration_cleanup_jobs
  WHERE author_id = p_user_id;

  -- Archive every character row and detach its active owner. Do not set deleted_at:
  -- this is account archival, not character-content deletion.
  UPDATE public.characters AS c
  SET creator_display_name =
        COALESCE(NULLIF(c.creator_display_name, ''),
                 NULLIF(v_nickname, ''),
                   '原作者'),
      -- Preserve the existing public/private visibility and review state.
      -- Account deletion marks the character offline; it does not delist the work.
      account_archived_at = COALESCE(c.account_archived_at, v_archived_at),
      author_id = NULL
  WHERE c.author_id = p_user_id;

  GET DIAGNOSTICS v_character_count = ROW_COUNT;
  RETURN v_character_count;
END;
$function$;

REVOKE ALL ON FUNCTION private.archive_account_characters(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.archive_account_characters(uuid)
  TO service_role;

-- 7) Transactional integration with the live prepare_account_deletion(uuid).
-- The complete replacement function, copied from the current test-DB definition
-- and amended with safe retry handling, lives in:
--   supabase/drafts/prepare-account-deletion-character-preservation-integration.sql
--
-- It deliberately does NOT call the helper before looking up the existing batch:
-- a retry after Auth deletion must not require the now-deleted profile row.
-- Instead it:
--   - returns immediately for an already-deleting batch, unless legacy owned
--     character rows still exist (then it archives those rows before returning);
--   - calls the helper for existing archived/archiving batches; and
--   - calls the helper for a new batch before any irreversible cleanup.
-- All helper calls execute inside the same prepare_account_deletion transaction.
-- The worker's deleting-recovery branch then performs only Auth/finalize steps.
--
-- disposable PostgreSQL replay, RLS/Storage tests and end-to-end deletion tests pass.

-- ============================================================================
-- E. Database guard against new sessions for account-archived characters
-- ============================================================================

-- Defense-in-depth for account-archived characters.
-- Requires public.characters.account_archived_at from
-- account-deletion-character-preservation-draft.sql.
-- PostgreSQL replay are complete.

-- Edge Functions already perform caller-JWT eligibility checks, but trusted
-- service-role creation RPCs are privileged entrypoints. Enforce the archive
-- state again at the database INSERT boundary so a future Edge/RPC regression
-- cannot create a new conversation for an account-archived character.
CREATE OR REPLACE FUNCTION private.reject_account_archived_character_entry()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_character_id uuid;
  v_character_unavailable boolean;
BEGIN
  v_character_id := NULLIF(COALESCE(
    pg_catalog.to_jsonb(NEW) ->> 'character_id',
    pg_catalog.to_jsonb(NEW) ->> 'world_character_id'
  ), '')::uuid;

  -- Legacy conversations reference character_stories rather than characters.
  -- Lock the owning character too, or a conversation INSERT could race a
  -- hard-delete and then be cascaded away through story_id.
  IF v_character_id IS NULL THEN
    SELECT cs.character_id
      INTO v_character_id
    FROM public.character_stories AS cs
    WHERE cs.id = NULLIF(pg_catalog.to_jsonb(NEW) ->> 'story_id', '')::uuid;
  END IF;

  IF v_character_id IS NOT NULL THEN
    -- Serialize new-entry creation with soft_delete_character()'s FOR UPDATE
    -- lock. If the insert wins, deletion waits and its history check sees the
    -- committed parent. If deletion wins, this insert waits and then fails.
    SELECT (c.deleted_at IS NOT NULL OR c.account_archived_at IS NOT NULL)
      INTO v_character_unavailable
    FROM public.characters AS c
    WHERE c.id = v_character_id
    FOR KEY SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'character_not_available'
        USING ERRCODE = '42501';
    END IF;

    IF v_character_unavailable IS TRUE THEN
      RAISE EXCEPTION 'character_not_available'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.reject_account_archived_character_entry()
  FROM PUBLIC, anon, authenticated, service_role;

-- Single chat, encounter, story, and group membership are all new-entry writes.
-- Existing chat continuation writes to message/turn tables and is deliberately
-- not guarded here.
DROP TRIGGER IF EXISTS reject_archived_character_new_chat
  ON public.chat_sessions;
CREATE TRIGGER reject_archived_character_new_chat
  BEFORE INSERT OR UPDATE OF character_id ON public.chat_sessions
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

DROP TRIGGER IF EXISTS reject_archived_character_new_world_group
  ON public.chat_groups;
CREATE TRIGGER reject_archived_character_new_world_group
  BEFORE INSERT OR UPDATE OF world_character_id ON public.chat_groups
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

DROP TRIGGER IF EXISTS reject_archived_character_new_group_member
  ON public.chat_group_members;
CREATE TRIGGER reject_archived_character_new_group_member
  BEFORE INSERT OR UPDATE OF character_id ON public.chat_group_members
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

DROP TRIGGER IF EXISTS reject_archived_character_new_encounter
  ON public.encounter_session_lifecycle;
CREATE TRIGGER reject_archived_character_new_encounter
  BEFORE INSERT OR UPDATE OF character_id ON public.encounter_session_lifecycle
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

DROP TRIGGER IF EXISTS reject_archived_character_new_story
  ON public.story_relationship_states;
CREATE TRIGGER reject_archived_character_new_story
  BEFORE INSERT OR UPDATE OF character_id ON public.story_relationship_states
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

-- Legacy conversations have no direct character_id FK: they point to a story,
-- which then cascades from characters. Guard story_id writes explicitly so
-- history-aware hard deletion cannot race and cascade away a newly inserted chat.
DROP TRIGGER IF EXISTS reject_archived_character_legacy_conversation
  ON public.conversations;
CREATE TRIGGER reject_archived_character_legacy_conversation
  BEFORE INSERT OR UPDATE OF story_id ON public.conversations
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

-- Existing legacy messages are continuation writes and are deliberately not
-- guarded. Only creating/reassigning the conversation parent is blocked.

-- Regression requirements for disposable PostgreSQL:
-- 1. Account archive marker set: INSERT chat_sessions for that character fails.
-- 2. Account archive marker set: INSERT chat_group_members fails.
-- 3. Account archive marker set: INSERT encounter_session_lifecycle fails.
-- 4. Account archive marker set: INSERT story_relationship_states fails.
-- 5. Existing chat_messages / chat_group_messages / encounter turns can continue
--    for their already-authorized, non-deleted parent; no trigger is attached to
--    these continuation tables.
-- 6. Non-archived characters preserve existing creation behavior.
-- 7. A failure in any parent/child insert transaction rolls back all rows.

-- ============================================================================
-- F. Freeze author-managed character child writes during pending deletion
-- ============================================================================

-- Consistent pending-account-deletion RLS freeze for author-managed character data.
--
-- Existing owner policies remain the permissive ownership/visibility checks.
-- These additional RESTRICTIVE policies are AND gates for authenticated users:
-- a pending-deletion account cannot read or mutate these owner-managed rows.
-- Public/anon reads are not changed because these policies target authenticated.
--
-- Pair with account-is-active-auth-user-existence-guard.sql so stale JWTs for
-- deleted Auth users also fail account_is_active().

DO $policy$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'character_private_info'
      AND c.relkind = 'r'
  ) THEN
    RAISE EXCEPTION 'required table public.character_private_info is missing';
  END IF;
END;
$policy$;

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_private_info;
CREATE POLICY account_must_be_active
  ON public.character_private_info
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_schedules;
CREATE POLICY account_must_be_active
  ON public.character_schedules
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_schedule_descriptions;
CREATE POLICY account_must_be_active
  ON public.character_schedule_descriptions
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_illustrations;
CREATE POLICY account_must_be_active
  ON public.character_illustrations
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

-- No policy is added to character_comments or character_comment_likes here:
-- those are player-authored social records, not author-owned character settings.
-- Their deletion/anonymization policy is separate from character retention.

-- ============================================================================
-- G. Preserve existing group chat continuation after character deletion
-- ============================================================================

-- Existing group membership is a durable conversation snapshot. Character deletion
-- hides a character from public discovery/new chats, but never removes its speaking
-- turn or billing from a group that already exists.

CREATE OR REPLACE FUNCTION public.append_chat_group_mock_turn(
  p_group_id uuid,
  p_request_key uuid,
  p_content text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_turn_id uuid;
  v_existing_content text;
  v_member_count integer;
  v_cost integer;
  v_silver integer;
  v_diamonds integer;
  v_balance_silver integer;
  v_balance_diamonds integer;
  v_pick integer;
  v_character_id uuid;
  v_scene_id uuid;
  v_character_name text;
  v_style text;
  v_scene_name text;
  v_character_snapshot jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF NOT public.account_is_active() THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;
  IF p_request_key IS NULL THEN
    RAISE EXCEPTION 'request_key_required' USING ERRCODE = '22023';
  END IF;
  IF p_content IS NULL OR char_length(btrim(p_content)) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'invalid_message_content' USING ERRCODE = '22023';
  END IF;

  -- Serialize against group deletion before touching wallet/turn/message rows.
  PERFORM 1
  FROM public.chat_groups g
  WHERE g.id = p_group_id
    AND g.owner_id = v_user_id
    AND g.archived_at IS NULL
    AND g.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'group_not_found_or_not_accessible' USING ERRCODE = '42501';
  END IF;

  SELECT t.id, t.request_content
    INTO v_turn_id, v_existing_content
  FROM public.chat_group_turns t
  WHERE t.group_id = p_group_id
    AND t.request_key = p_request_key;
  IF FOUND THEN
    IF v_existing_content IS DISTINCT FROM btrim(p_content) THEN
      RAISE EXCEPTION 'idempotency_key_reused_with_different_content' USING ERRCODE = '22023';
    END IF;
    RETURN v_turn_id;
  END IF;

  -- Existing group membership is a durable conversation snapshot.
  -- A character deletion hides the character from public discovery/new chats,
  -- but MUST NOT remove its speaking turn or billing from an existing group.
  SELECT count(*)::integer INTO v_member_count
  FROM public.chat_group_members m
  WHERE m.group_id = p_group_id;
  IF v_member_count NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'group_has_no_members' USING ERRCODE = '23514';
  END IF;

  v_cost := v_member_count * 3;
  PERFORM public.ensure_wallet_account();

  SELECT w.silver_coins, w.diamonds
    INTO v_balance_silver, v_balance_diamonds
  FROM public.wallet_accounts w
  WHERE w.user_id = v_user_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'wallet_not_initialized'; END IF;

  IF COALESCE(v_balance_silver, 0) + COALESCE(v_balance_diamonds, 0) < v_cost THEN
    RAISE EXCEPTION 'group_insufficient_funds: required %, available %',
      v_cost, COALESCE(v_balance_silver, 0) + COALESCE(v_balance_diamonds, 0)
      USING ERRCODE = 'P0001';
  END IF;

  v_silver := LEAST(v_balance_silver, v_cost);
  v_diamonds := v_cost - v_silver;

  UPDATE public.wallet_accounts w
  SET silver_coins=w.silver_coins-v_silver,
      diamonds=w.diamonds-v_diamonds,
      updated_at=now()
  WHERE w.user_id=v_user_id;

  SELECT count(*)::integer % v_member_count INTO v_pick
  FROM public.chat_group_turns t
  WHERE t.group_id=p_group_id;

  INSERT INTO public.chat_group_turns(group_id,user_id,request_key,request_content)
  VALUES (p_group_id,v_user_id,p_request_key,btrim(p_content))
  ON CONFLICT (group_id,request_key) DO NOTHING
  RETURNING id INTO v_turn_id;

  IF v_turn_id IS NULL THEN
    RAISE EXCEPTION 'group_turn_request_conflict' USING ERRCODE = '40001';
  END IF;

  SELECT
    m.character_id,m.scene_id,m.character_snapshot,
    COALESCE(m.character_snapshot->>'name','角色'),
    COALESCE(m.character_snapshot->>'style',m.character_snapshot->>'intro','我會仔細留意目前的情況。'),
    COALESCE(s.name,'目前場景')
  INTO
    v_character_id,v_scene_id,v_character_snapshot,
    v_character_name,v_style,v_scene_name
  FROM public.chat_group_members m
  LEFT JOIN public.chat_group_scenes s
    ON s.id=m.scene_id AND s.group_id=m.group_id
  WHERE m.group_id=p_group_id
  ORDER BY m.position
  OFFSET v_pick
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group_active_speaker_not_found' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.chat_group_messages(
    group_id,scene_id,turn_id,sequence_no,speaker_type,character_id,content
  )
  VALUES (p_group_id,v_scene_id,v_turn_id,0,'user',NULL,btrim(p_content));

  INSERT INTO public.chat_group_messages(
    group_id,scene_id,turn_id,sequence_no,speaker_type,character_id,content,speaker_snapshot
  )
  VALUES (
    p_group_id,v_scene_id,v_turn_id,1,'character',v_character_id,
    format('聽見你的話，%s 回應：「我明白了。%s 我們可以從「%s」開始，你接下來想怎麼做？」',
      v_character_name,v_style,v_scene_name),
    jsonb_build_object(
      'id',COALESCE(v_character_snapshot->>'id',v_character_id::text),
      'name',v_character_name
    )
  );

  INSERT INTO public.chat_group_turn_charges(
    group_id,group_turn_id,user_id,request_key,
    member_count,cost,silver_charged,diamonds_charged,status
  )
  VALUES (
    p_group_id,v_turn_id,v_user_id,p_request_key,
    v_member_count,v_cost,v_silver,v_diamonds,'settled'
  );

  IF v_silver > 0 THEN
    INSERT INTO public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id)
    VALUES (v_user_id,'silver_coins',-v_silver,'group_chat_turn_charge',v_turn_id::text);
  END IF;
  IF v_diamonds > 0 THEN
    INSERT INTO public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id)
    VALUES (v_user_id,'diamonds',-v_diamonds,'group_chat_turn_charge',v_turn_id::text);
  END IF;

  UPDATE public.chat_groups SET updated_at=now() WHERE id=p_group_id;
  RETURN v_turn_id;
END;
$function$;

-- CREATE OR REPLACE preserves the existing function ACL. Do not widen it here.

-- ============================================================================
-- H. Integrate character preservation and photo retention into account prepare
-- ============================================================================

-- Exact prepare_account_deletion(uuid) replacement based on the live test DB
-- pg_get_functiondef() inspected 2026-11-02, with character-preservation calls.
-- account-deletion-character-preservation-draft.sql to be reviewed and replayed
-- on a disposable local database first.
--
-- Retry safety:
--   1. An already-deleting batch returns without requiring the profile row.
--   2. If legacy deleting batches still have author-owned characters, archive them
--      first (only when such rows exist); this is safe even after Auth deletion.
--   3. Existing archived/archiving batch and new-batch paths call the helper before
--      any irreversible cleanup. Both calls are in this same function transaction.
--
-- This is a complete replacement of the current live function definition, not
-- a partial snippet. Re-diff against pg_get_functiondef() immediately before use.

-- Queue account-owned chat-memory photo paths only when the irreversible account
-- deletion prepare step begins (after the environment-specific account grace period).
-- Photos retain their own fixed 30-day clock from requested_at. A cancellation before
-- prepare creates no photo cleanup work. Queue rows survive Auth cascades.
CREATE OR REPLACE FUNCTION private.enqueue_account_chat_memory_photo_cleanup(
  p_user_id uuid,
  p_requested_at timestamptz,
  p_scheduled_for timestamptz
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_photo record;
  v_locked_photo public.chat_memory_photos%ROWTYPE;
  v_parent_owner uuid;
  v_parent_deleted_at timestamptz;
  v_resource_type text;
  v_resource_id uuid;
  v_deleted_at timestamptz;
  v_job_id uuid;
  v_job public.chat_deletion_jobs%ROWTYPE;
  v_storage_job public.chat_storage_deletion_jobs%ROWTYPE;
  v_queued integer := 0;
BEGIN
  IF p_user_id IS NULL OR p_requested_at IS NULL OR p_scheduled_for IS NULL
     OR p_scheduled_for <= p_requested_at THEN
    RAISE EXCEPTION 'account_chat_photo_retention_window_mismatch';
  END IF;

  FOR v_photo IN
    SELECT p.id, p.owner_id, p.chat_type, p.session_id, p.group_id, p.storage_path
    FROM public.chat_memory_photos AS p
    WHERE p.owner_id = p_user_id
    -- Match snapshot_account_chat_character_history(): lock all solo parents
    -- first (stable ID order), then all group parents, preventing inverse-order
    -- deadlocks when account preparation and other lifecycle writers overlap.
    ORDER BY CASE WHEN p.chat_type = 'single' THEN 0 ELSE 1 END,
      COALESCE(p.session_id, p.group_id), p.id
  LOOP
    IF v_photo.storage_path !~ ('^' || p_user_id::text || '/')
       OR char_length(v_photo.storage_path) > 1024 THEN
      RAISE EXCEPTION 'account_chat_photo_storage_path_invalid';
    END IF;

    IF v_photo.chat_type = 'single' THEN
      v_resource_type := 'single_session';
      v_resource_id := v_photo.session_id;
      SELECT s.user_id, s.deleted_at
        INTO v_parent_owner, v_parent_deleted_at
      FROM public.chat_sessions AS s
      WHERE s.id = v_resource_id
      FOR UPDATE;
    ELSIF v_photo.chat_type = 'group' THEN
      v_resource_type := 'group';
      v_resource_id := v_photo.group_id;
      SELECT g.owner_id, g.deleted_at
        INTO v_parent_owner, v_parent_deleted_at
      FROM public.chat_groups AS g
      WHERE g.id = v_resource_id
      FOR UPDATE;
    ELSE
      RAISE EXCEPTION 'account_chat_photo_type_invalid';
    END IF;

    IF NOT FOUND OR v_parent_owner IS DISTINCT FROM p_user_id THEN
      RAISE EXCEPTION 'account_chat_photo_parent_owner_mismatch';
    END IF;

    -- Preserve the common parent-first lock order used by chat writers. The
    -- initial photo scan is unlocked; re-lock and verify the exact row only
    -- after its parent has been locked to avoid delete/photo-write deadlocks.
    SELECT p.* INTO v_locked_photo
    FROM public.chat_memory_photos AS p
    WHERE p.id = v_photo.id
    FOR UPDATE;

    IF NOT FOUND
       OR v_locked_photo.owner_id IS DISTINCT FROM p_user_id
       OR v_locked_photo.chat_type IS DISTINCT FROM v_photo.chat_type
       OR v_locked_photo.session_id IS DISTINCT FROM v_photo.session_id
       OR v_locked_photo.group_id IS DISTINCT FROM v_photo.group_id
       OR v_locked_photo.storage_path IS DISTINCT FROM v_photo.storage_path THEN
      RAISE EXCEPTION 'account_chat_photo_changed_during_queueing';
    END IF;

    -- Existing soft-deleted chats keep their original deletion clock. Active
    -- account-owned chats receive the account request timestamp. Photo retention
    -- is independently fixed at 30 days even when a test environment uses a shorter
    -- account grace period; cancellation before prepare creates no cleanup jobs.
    v_deleted_at := COALESCE(v_parent_deleted_at, p_requested_at);

    -- An account-prepare photo job can outlive a failed/interrupted Auth cascade.
    -- Mark the owned parent with the exact same retention timestamp so the normal
    -- day-30 purge RPC can still validate and purge it if the parent remains present.
    -- The account worker uses a service-role JWT without an end-user sub claim; this
    -- is an internal lifecycle transition, not a user-authored chat update.
    IF v_resource_type = 'single_session' THEN
      UPDATE public.chat_sessions AS s
      SET deleted_at = COALESCE(s.deleted_at, v_deleted_at),
          updated_at = pg_catalog.statement_timestamp()
      WHERE s.id = v_resource_id
        AND s.user_id = p_user_id
        AND s.deleted_at IS NOT DISTINCT FROM v_parent_deleted_at;
    ELSE
      UPDATE public.chat_groups AS g
      SET deleted_at = COALESCE(g.deleted_at, v_deleted_at),
          updated_at = pg_catalog.statement_timestamp()
      WHERE g.id = v_resource_id
        AND g.owner_id = p_user_id
        AND g.deleted_at IS NOT DISTINCT FROM v_parent_deleted_at;
    END IF;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'account_chat_photo_parent_changed_during_queueing';
    END IF;

    INSERT INTO public.chat_deletion_jobs (
      resource_type, resource_id, owner_id, deleted_at, purge_after
    ) VALUES (
      v_resource_type, v_resource_id, p_user_id, v_deleted_at,
      v_deleted_at + interval '30 days'
    )
    ON CONFLICT (resource_type, resource_id) DO NOTHING;

    SELECT j.* INTO v_job
    FROM public.chat_deletion_jobs AS j
    WHERE j.resource_type = v_resource_type
      AND j.resource_id = v_resource_id
    FOR UPDATE;

    IF NOT FOUND OR v_job.owner_id IS DISTINCT FROM p_user_id
       OR v_job.deleted_at IS DISTINCT FROM v_deleted_at
       OR v_job.purge_after IS DISTINCT FROM v_deleted_at + interval '30 days' THEN
      RAISE EXCEPTION 'account_chat_photo_deletion_job_conflict';
    END IF;

    INSERT INTO public.chat_storage_deletion_jobs (
      deletion_job_id, bucket_id, object_path, resource_type, resource_id, owner_id
    ) VALUES (
      v_job.id, 'personax-memory-photos', v_photo.storage_path,
      v_resource_type, v_resource_id, p_user_id
    )
    ON CONFLICT (bucket_id, object_path) DO NOTHING;

    SELECT sj.* INTO v_storage_job
    FROM public.chat_storage_deletion_jobs AS sj
    WHERE sj.bucket_id = 'personax-memory-photos'
      AND sj.object_path = v_photo.storage_path
    FOR UPDATE;

    IF NOT FOUND OR v_storage_job.deletion_job_id IS DISTINCT FROM v_job.id
       OR v_storage_job.resource_type IS DISTINCT FROM v_resource_type
       OR v_storage_job.resource_id IS DISTINCT FROM v_resource_id
       OR v_storage_job.owner_id IS DISTINCT FROM p_user_id THEN
      RAISE EXCEPTION 'account_chat_photo_storage_job_conflict';
    END IF;

    v_queued := v_queued + 1;
  END LOOP;

  RETURN v_queued;
END;
$function$;

REVOKE ALL ON FUNCTION private.enqueue_account_chat_memory_photo_cleanup(uuid, timestamptz, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.enqueue_account_chat_memory_photo_cleanup(uuid, timestamptz, timestamptz)
  TO postgres;

-- Group chat charges are independent financial/idempotency evidence. The
-- group parent and auth user both cascade to these rows, so archive them first.
-- Group turn request_content is transcript content: retain only the minimal
-- idempotency metadata, never the player's message text.
ALTER TABLE public.account_deletion_archive_items
  DROP CONSTRAINT IF EXISTS account_deletion_archive_items_source_table_check;
ALTER TABLE public.account_deletion_archive_items
  ADD CONSTRAINT account_deletion_archive_items_source_table_check
  CHECK (source_table IN (
    'ai_generation_records',
    'wallet_transactions',
    'chat_turn_charges',
    'chat_turn_events',
    'chat_group_turn_charges',
    'chat_group_turns'
  ));

CREATE OR REPLACE FUNCTION public.prepare_account_deletion(p_user_id uuid)
 RETURNS TABLE(batch_id uuid, target_user_id uuid, batch_status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_requested_at timestamptz;
  v_scheduled_for timestamptz;
  v_batch_id uuid;
  v_status text;
  v_ai_source bigint;
  v_ai_archived bigint;
  v_wallet_source bigint;
  v_wallet_archived bigint;
  v_charge_source bigint;
  v_charge_archived bigint;
  v_event_source bigint;
  v_event_archived bigint;
  v_group_charge_source bigint;
  v_group_charge_archived bigint;
  v_group_turn_source bigint;
  v_group_turn_archived bigint;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION '目標帳號不可為空';
  END IF;

  SELECT r.requested_at, r.scheduled_for
    INTO v_requested_at, v_scheduled_for
  FROM public.account_deletion_requests AS r
  WHERE r.user_id = p_user_id
    AND r.scheduled_for <= pg_catalog.statement_timestamp()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到此帳號已到期的刪除申請';
  END IF;

  -- Enqueue only after the recovery deadline has elapsed and this exact
  -- request row is locked. A cancellation that wins before this point leaves
  -- no photo cleanup jobs behind; queue retention ends at scheduled_for.
  PERFORM private.enqueue_account_chat_memory_photo_cleanup(
    p_user_id, v_requested_at, v_scheduled_for
  );

  -- Account deletion bypasses chat soft-delete RPCs; preserve character-use
  -- tombstones and completed assistant-turn totals before Auth FK cascades.
  -- This is idempotent and shares this transaction with all later archive steps.
  PERFORM private.snapshot_account_chat_character_history(p_user_id);

  -- Lock/reuse this exact request's batch. Never create a second active batch.
  SELECT b.id, b.status
    INTO v_batch_id, v_status
  FROM public.account_deletion_archive_batches AS b
  WHERE b.target_user_id = p_user_id
    AND b.requested_at = v_requested_at
    AND b.scheduled_for = v_scheduled_for
    AND b.status NOT IN ('completed', 'cancelled')
  ORDER BY b.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND AND v_status = 'deleting' THEN
    -- New-code deleting batches already committed character archival atomically.
    -- Heal a legacy deleting batch only if owned character rows are still present;
    -- this also keeps a retry safe after the Auth profile has already disappeared.
    IF EXISTS (
      SELECT 1 FROM public.characters AS c
      WHERE c.author_id = p_user_id
    ) THEN
      PERFORM private.archive_account_characters(p_user_id);
    END IF;
    -- The status change and relational cleanup commit in one PostgreSQL transaction.
    -- Therefore a committed deleting batch means cleanup already completed; do not
    -- compare now-empty source tables with their preserved archive row counts.
    RETURN QUERY SELECT v_batch_id, p_user_id, 'deleting'::text;
    RETURN;
  ELSIF FOUND THEN
    -- The Auth profile still exists while this branch is active. Archive all of its
    -- characters in this same transaction before marking the batch deleting.
    PERFORM private.archive_account_characters(p_user_id);

    -- Backfill billing/audit snapshots for older batches created before these source
    -- tables were added to the archive. ON CONFLICT preserves any prior payload so the
    -- exact-payload checks below still fail closed on a conflicting existing snapshot.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_charges', c.turn_id::text, pg_catalog.to_jsonb(c)
    FROM public.chat_turn_charges AS c
    WHERE c.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_events', e.event_id::text, pg_catalog.to_jsonb(e)
    FROM public.chat_turn_events AS e
    WHERE e.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turn_charges', gc.id::text, pg_catalog.to_jsonb(gc)
    FROM public.chat_group_turn_charges AS gc
    WHERE gc.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    -- Exclude request_content and user_id: this preserves retry/idempotency
    -- metadata without retaining the group player's transcript text.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turns', gt.id::text,
      pg_catalog.jsonb_build_object(
        'id', gt.id,
        'group_id', gt.group_id,
        'request_key', gt.request_key,
        'status', gt.status,
        'created_at', gt.created_at,
        'completed_at', gt.completed_at
      )
    FROM public.chat_group_turns AS gt
    WHERE gt.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    -- A failed or interrupted archive can be retried only if every remaining source row
    -- is exactly represented in the existing archive. Any mismatch fails closed.
    SELECT count(*) INTO v_ai_source
    FROM public.ai_generation_records AS a WHERE a.user_id = p_user_id;
    SELECT count(*) INTO v_wallet_source
    FROM public.wallet_transactions AS w WHERE w.user_id = p_user_id;
    SELECT count(*) INTO v_ai_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'ai_generation_records';
    SELECT count(*) INTO v_wallet_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'wallet_transactions';
    SELECT count(*) INTO v_charge_source
    FROM public.chat_turn_charges AS c WHERE c.user_id = p_user_id;
    SELECT count(*) INTO v_charge_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_charges';
    SELECT count(*) INTO v_event_source
    FROM public.chat_turn_events AS e WHERE e.user_id = p_user_id;
    SELECT count(*) INTO v_event_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_events';
    SELECT count(*) INTO v_group_charge_source
    FROM public.chat_group_turn_charges AS gc WHERE gc.user_id = p_user_id;
    SELECT count(*) INTO v_group_charge_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turn_charges';
    SELECT count(*) INTO v_group_turn_source
    FROM public.chat_group_turns AS gt WHERE gt.user_id = p_user_id;
    SELECT count(*) INTO v_group_turn_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turns';

    IF v_ai_source <> v_ai_archived OR v_wallet_source <> v_wallet_archived
       OR v_charge_source <> v_charge_archived OR v_event_source <> v_event_archived
       OR v_group_charge_source <> v_group_charge_archived
       OR v_group_turn_source <> v_group_turn_archived
       OR EXISTS (
         SELECT 1 FROM public.ai_generation_records AS a
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'ai_generation_records'
          AND i.source_record_id = a.id::text
         WHERE a.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(a))
       )
       OR EXISTS (
         SELECT 1 FROM public.wallet_transactions AS w
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'wallet_transactions'
          AND i.source_record_id = w.id::text
         WHERE w.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(w))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_turn_charges AS c
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_turn_charges'
          AND i.source_record_id = c.turn_id::text
         WHERE c.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(c))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_turn_events AS e
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_turn_events'
          AND i.source_record_id = e.event_id::text
         WHERE e.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(e))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_group_turn_charges AS gc
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_group_turn_charges'
          AND i.source_record_id = gc.id::text
         WHERE gc.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(gc))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_group_turns AS gt
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_group_turns'
          AND i.source_record_id = gt.id::text
         WHERE gt.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.jsonb_build_object(
             'id', gt.id,
             'group_id', gt.group_id,
             'request_key', gt.request_key,
             'status', gt.status,
             'created_at', gt.created_at,
             'completed_at', gt.completed_at
           ))
       ) THEN
      RAISE EXCEPTION '既有封存批次與來源資料不一致，已停止刪除以避免資料遺失';
    END IF;

    UPDATE public.account_deletion_archive_batches AS b
    SET status = 'archived',
        attempt_count = b.attempt_count + 1,
        started_at = pg_catalog.statement_timestamp(),
        updated_at = pg_catalog.statement_timestamp(),
        last_error = NULL
    WHERE b.id = v_batch_id;
  ELSE
    -- No existing batch: preserve/detach every character before creating the archive
    -- batch. Any later failure rolls this change back with the same transaction.
    PERFORM private.archive_account_characters(p_user_id);

    SELECT a.batch_id INTO v_batch_id
    FROM public.archive_account_deletion_data(p_user_id) AS a
    LIMIT 1;

    -- Preserve billing/audit rows as well as the original AI and wallet archive payloads.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_charges', c.turn_id::text, pg_catalog.to_jsonb(c)
    FROM public.chat_turn_charges AS c
    WHERE c.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_events', e.event_id::text, pg_catalog.to_jsonb(e)
    FROM public.chat_turn_events AS e
    WHERE e.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turn_charges', gc.id::text, pg_catalog.to_jsonb(gc)
    FROM public.chat_group_turn_charges AS gc
    WHERE gc.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    -- Exclude request_content and user_id: this preserves retry/idempotency
    -- metadata without retaining the group player's transcript text.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turns', gt.id::text,
      pg_catalog.jsonb_build_object(
        'id', gt.id,
        'group_id', gt.group_id,
        'request_key', gt.request_key,
        'status', gt.status,
        'created_at', gt.created_at,
        'completed_at', gt.completed_at
      )
    FROM public.chat_group_turns AS gt
    WHERE gt.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    v_status := 'archived';
  END IF;

  -- Verify billing/audit archive rows too before any irreversible deletion.
  SELECT count(*) INTO v_charge_source
  FROM public.chat_turn_charges AS c WHERE c.user_id = p_user_id;
  SELECT count(*) INTO v_charge_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_charges';
  SELECT count(*) INTO v_event_source
  FROM public.chat_turn_events AS e WHERE e.user_id = p_user_id;
  SELECT count(*) INTO v_event_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_events';
  SELECT count(*) INTO v_group_charge_source
  FROM public.chat_group_turn_charges AS gc WHERE gc.user_id = p_user_id;
  SELECT count(*) INTO v_group_charge_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turn_charges';
  SELECT count(*) INTO v_group_turn_source
  FROM public.chat_group_turns AS gt WHERE gt.user_id = p_user_id;
  SELECT count(*) INTO v_group_turn_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turns';

  IF v_charge_source <> v_charge_archived OR v_event_source <> v_event_archived
     OR v_group_charge_source <> v_group_charge_archived
     OR v_group_turn_source <> v_group_turn_archived
     OR EXISTS (
       SELECT 1 FROM public.chat_turn_charges AS c
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_turn_charges'
        AND i.source_record_id = c.turn_id::text
       WHERE c.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(c))
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_turn_events AS e
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_turn_events'
        AND i.source_record_id = e.event_id::text
       WHERE e.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(e))
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_group_turn_charges AS gc
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_group_turn_charges'
        AND i.source_record_id = gc.id::text
       WHERE gc.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(gc))
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_group_turns AS gt
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_group_turns'
        AND i.source_record_id = gt.id::text
       WHERE gt.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.jsonb_build_object(
           'id', gt.id,
           'group_id', gt.group_id,
           'request_key', gt.request_key,
           'status', gt.status,
           'created_at', gt.created_at,
           'completed_at', gt.completed_at
         ))
     ) THEN
    RAISE EXCEPTION '聊天扣款／事件紀錄封存核對失敗，已停止刪除';
  END IF;

  -- Archive verified: mark the irreversible phase before deleting source rows.
  UPDATE public.account_deletion_archive_batches AS b
  SET status = 'deleting',
      attempt_count = CASE WHEN b.attempt_count = 0 THEN 1 ELSE b.attempt_count END,
      started_at = COALESCE(b.started_at, pg_catalog.statement_timestamp()),
      updated_at = pg_catalog.statement_timestamp(),
      last_error = NULL
  WHERE b.id = v_batch_id;

  -- Remove non-cascading references before chat/profile/Auth deletion.
  DELETE FROM public.ai_generation_records WHERE user_id = p_user_id;

  -- Delete version history only for messages owned by the account being deleted.
  -- If this user edited another player's message, preserve that player's version rows
  -- and anonymize the editor reference instead of deleting someone else's history.
  DELETE FROM public.chat_message_versions AS v
  WHERE v.message_id IN (
    SELECT m.id
    FROM public.chat_messages AS m
    JOIN public.chat_sessions AS s ON s.id = m.session_id
    WHERE s.user_id = p_user_id
  );

  UPDATE public.chat_message_versions AS v
  SET edited_by = NULL
  WHERE v.edited_by = p_user_id
    AND NOT EXISTS (
      SELECT 1
      FROM public.chat_messages AS m
      JOIN public.chat_sessions AS s ON s.id = m.session_id
      WHERE m.id = v.message_id
        AND s.user_id = p_user_id
    );

  -- user_message_id uses ON DELETE RESTRICT, so charges must be removed before messages.
  DELETE FROM public.chat_turn_charges WHERE user_id = p_user_id;

  DELETE FROM public.wallet_transactions WHERE user_id = p_user_id;

  -- Old conversation schema and role/chat data are owned by the profile; their declared
  -- CASCADE relationships remove stories, private info, conversations/messages and sessions.
  -- Explicitly remove conversations first so the cleanup is clear and retry-safe.
  DELETE FROM public.conversations WHERE user_id = p_user_id;

  RETURN QUERY SELECT v_batch_id, p_user_id, 'deleting'::text;
END;
$function$;

-- ============================================================================
-- I. Atomic account-deletion worker lease and fencing protocol
-- ============================================================================

-- A production migration must be generated/reconciled separately after the missing

CREATE TABLE IF NOT EXISTS public.account_deletion_work_leases (
  target_user_id uuid PRIMARY KEY,
  requested_at timestamptz NOT NULL,
  scheduled_for timestamptz NOT NULL,
  lease_token uuid NOT NULL,
  lease_generation bigint NOT NULL DEFAULT 0 CHECK (lease_generation >= 0),
  lease_expires_at timestamptz NOT NULL,
  lease_status text NOT NULL CHECK (lease_status IN ('claimed', 'completed', 'cancelled')),
  batch_id uuid,
  claimed_at timestamptz NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  last_error text
);

COMMENT ON TABLE public.account_deletion_work_leases IS
  'Durable service-only account deletion worker lease. Intentionally has no Auth/request FK so recovery survives profile/Auth cascades.';

ALTER TABLE public.account_deletion_work_leases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.account_deletion_work_leases FROM PUBLIC, anon, authenticated, service_role;

-- One invocation claims one account. Ten minutes is a provisional bounded lease;
-- keep the limit at one until local phase-duration telemetry supports a different value.
-- Renew is required immediately before every external Auth Admin call and finalization.
CREATE OR REPLACE FUNCTION public.claim_account_deletion_work_items(p_limit integer DEFAULT 1)
RETURNS TABLE(
  target_user_id uuid,
  batch_id uuid,
  scheduled_for timestamptz,
  work_status text,
  lease_token uuid,
  lease_generation bigint,
  lease_expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_request record;
  v_batch record;
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_id uuid;
  v_active_count integer;
  v_claimed integer := 0;
  v_now timestamptz := pg_catalog.statement_timestamp();
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'invalid_account_deletion_claim_limit' USING ERRCODE = '22023';
  END IF;

  -- Due requests: lock request first, then lease, then any archive batch.
  FOR v_request IN
    SELECT q.user_id, q.requested_at, q.scheduled_for
    FROM public.account_deletion_requests AS q
    WHERE q.scheduled_for <= v_now
      AND NOT EXISTS (
        SELECT 1
        FROM public.account_deletion_work_leases AS active_lease
        WHERE active_lease.target_user_id = q.user_id
          AND active_lease.lease_status = 'claimed'
          AND active_lease.lease_expires_at > v_now
      )
    ORDER BY q.scheduled_for, q.user_id
    FOR UPDATE SKIP LOCKED
  LOOP
    EXIT WHEN v_claimed >= p_limit;
    v_batch_id := NULL;
    SELECT pg_catalog.count(*)::integer
      INTO v_active_count
    FROM public.account_deletion_archive_batches AS b
    WHERE b.target_user_id = v_request.user_id
      AND b.requested_at = v_request.requested_at
      AND b.scheduled_for = v_request.scheduled_for
      AND b.status IN ('pending', 'archiving', 'archived', 'deleting');

    IF v_active_count > 1 THEN
      RAISE EXCEPTION 'duplicate_active_account_deletion_batches';
    END IF;

    -- Prefer a non-blocking lease lock before attempting first-row insertion.
    SELECT l.* INTO v_lease
    FROM public.account_deletion_work_leases AS l
    WHERE l.target_user_id = v_request.user_id
    FOR UPDATE SKIP LOCKED;

    IF NOT FOUND THEN
      IF EXISTS (
        SELECT 1 FROM public.account_deletion_work_leases AS existing_lease
        WHERE existing_lease.target_user_id = v_request.user_id
      ) THEN
        CONTINUE;
      END IF;

      INSERT INTO public.account_deletion_work_leases (
        target_user_id, requested_at, scheduled_for, lease_token,
        lease_generation, lease_expires_at, lease_status, batch_id
      ) VALUES (
        v_request.user_id, v_request.requested_at, v_request.scheduled_for,
        pg_catalog.gen_random_uuid(), 0, v_now,
        'cancelled', NULL
      )
      ON CONFLICT ON CONSTRAINT account_deletion_work_leases_pkey DO NOTHING;

      SELECT l.* INTO v_lease
      FROM public.account_deletion_work_leases AS l
      WHERE l.target_user_id = v_request.user_id
      FOR UPDATE SKIP LOCKED;

      IF NOT FOUND THEN
        CONTINUE;
      END IF;
    END IF;
    IF v_lease.lease_status = 'completed' AND v_active_count > 0 THEN
      RAISE EXCEPTION 'completed_account_deletion_lease_has_active_batch';
    END IF;

    IF v_lease.requested_at IS DISTINCT FROM v_request.requested_at
       OR v_lease.scheduled_for IS DISTINCT FROM v_request.scheduled_for THEN
      IF v_lease.lease_status <> 'cancelled' THEN
        RAISE EXCEPTION 'account_deletion_lease_request_identity_mismatch';
      END IF;
      UPDATE public.account_deletion_work_leases AS l
      SET requested_at = v_request.requested_at,
          scheduled_for = v_request.scheduled_for,
          lease_token = pg_catalog.gen_random_uuid(),
          lease_generation = l.lease_generation + 1,
          lease_expires_at = pg_catalog.clock_timestamp() + interval '10 minutes',
          lease_status = 'claimed',
          batch_id = v_batch_id,
          claimed_at = pg_catalog.clock_timestamp(),
          updated_at = pg_catalog.clock_timestamp(),
          attempt_count = 0,
          last_error = NULL
      WHERE l.target_user_id = v_request.user_id
      RETURNING l.* INTO v_lease;
    ELSE
      IF v_lease.lease_status = 'completed'
         OR (v_lease.lease_status = 'claimed' AND v_lease.lease_expires_at > v_now) THEN
        CONTINUE;
      END IF;
      UPDATE public.account_deletion_work_leases AS l
      SET lease_token = pg_catalog.gen_random_uuid(),
          lease_generation = l.lease_generation + 1,
          lease_expires_at = pg_catalog.clock_timestamp() + interval '10 minutes',
          lease_status = 'claimed',
          batch_id = COALESCE(v_batch_id, l.batch_id),
          claimed_at = pg_catalog.clock_timestamp(),
          updated_at = pg_catalog.clock_timestamp(),
          last_error = NULL
      WHERE l.target_user_id = v_request.user_id
      RETURNING l.* INTO v_lease;
    END IF;

    -- The request lock and lease lock are held before taking the batch lock.
    SELECT b.id INTO v_batch_id
    FROM public.account_deletion_archive_batches AS b
    WHERE b.target_user_id = v_request.user_id
      AND b.requested_at = v_request.requested_at
      AND b.scheduled_for = v_request.scheduled_for
      AND b.status NOT IN ('completed', 'cancelled')
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;

    UPDATE public.account_deletion_work_leases AS l
    SET batch_id = COALESCE(v_batch_id, l.batch_id),
        lease_expires_at = pg_catalog.clock_timestamp() + interval '10 minutes',
        updated_at = pg_catalog.clock_timestamp()
    WHERE l.target_user_id = v_request.user_id
      AND l.lease_token = v_lease.lease_token
      AND l.lease_generation = v_lease.lease_generation
    RETURNING l.* INTO v_lease;

    target_user_id := v_request.user_id;
    batch_id := v_batch_id;
    scheduled_for := v_request.scheduled_for;
    work_status := CASE WHEN v_batch_id IS NULL THEN 'due' ELSE 'archived' END;
    lease_token := v_lease.lease_token;
    lease_generation := v_lease.lease_generation;
    lease_expires_at := v_lease.lease_expires_at;
    RETURN NEXT;
    v_claimed := v_claimed + 1;
    EXIT WHEN v_claimed >= p_limit;
  END LOOP;

  -- Recover committed deleting batches whose request row was removed by prepare.
  -- The lease row is intentionally independent of Auth and request FKs.
  IF v_claimed < p_limit THEN
    FOR v_batch IN
      SELECT b.id, b.target_user_id, b.requested_at, b.scheduled_for
      FROM public.account_deletion_archive_batches AS b
      WHERE b.status = 'deleting'
        AND b.target_user_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.account_deletion_requests AS q
          WHERE q.user_id = b.target_user_id
            AND q.requested_at = b.requested_at
            AND q.scheduled_for = b.scheduled_for
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.account_deletion_work_leases AS active_lease
          WHERE active_lease.target_user_id = b.target_user_id
            AND active_lease.lease_status = 'claimed'
            AND active_lease.lease_expires_at > v_now
        )
      ORDER BY b.updated_at, b.id
    LOOP
      EXIT WHEN v_claimed >= p_limit;

      SELECT pg_catalog.count(*)::integer
        INTO v_active_count
      FROM public.account_deletion_archive_batches AS duplicate_batch
      WHERE duplicate_batch.target_user_id = v_batch.target_user_id
        AND duplicate_batch.requested_at = v_batch.requested_at
        AND duplicate_batch.scheduled_for = v_batch.scheduled_for
        AND duplicate_batch.status = 'deleting';
      IF v_active_count > 1 THEN
        RAISE EXCEPTION 'duplicate_deleting_account_batches';
      END IF;

      -- Recovery locks the lease first; an already locked row is skipped.
      SELECT l.* INTO v_lease
      FROM public.account_deletion_work_leases AS l
      WHERE l.target_user_id = v_batch.target_user_id
      FOR UPDATE SKIP LOCKED;

      IF NOT FOUND THEN
        IF EXISTS (
          SELECT 1 FROM public.account_deletion_work_leases AS existing_lease
          WHERE existing_lease.target_user_id = v_batch.target_user_id
        ) THEN
          CONTINUE;
        END IF;

        INSERT INTO public.account_deletion_work_leases (
          target_user_id, requested_at, scheduled_for, lease_token,
          lease_generation, lease_expires_at, lease_status, batch_id
        ) VALUES (
          v_batch.target_user_id, v_batch.requested_at, v_batch.scheduled_for,
          pg_catalog.gen_random_uuid(), 0, v_now,
          'cancelled', v_batch.id
        )
        ON CONFLICT ON CONSTRAINT account_deletion_work_leases_pkey DO NOTHING;

        SELECT l.* INTO v_lease
        FROM public.account_deletion_work_leases AS l
        WHERE l.target_user_id = v_batch.target_user_id
        FOR UPDATE SKIP LOCKED;

        IF NOT FOUND THEN
          CONTINUE;
        END IF;
      END IF;
      IF v_lease.requested_at IS DISTINCT FROM v_batch.requested_at
         OR v_lease.scheduled_for IS DISTINCT FROM v_batch.scheduled_for THEN
        RAISE EXCEPTION 'account_deletion_recovery_lease_identity_mismatch';
      END IF;
      IF v_lease.lease_status = 'completed' THEN
        RAISE EXCEPTION 'completed_account_deletion_lease_has_deleting_batch';
      END IF;
      IF v_lease.lease_status = 'claimed' AND v_lease.lease_expires_at > v_now THEN
        CONTINUE;
      END IF;

      -- Recovery lock order is lease -> batch because the request row no longer exists.
      PERFORM 1
      FROM public.account_deletion_archive_batches AS b
      WHERE b.id = v_batch.id
        AND b.status = 'deleting'
      FOR UPDATE SKIP LOCKED;
      IF NOT FOUND THEN
        CONTINUE;
      END IF;

      UPDATE public.account_deletion_work_leases AS l
      SET lease_token = pg_catalog.gen_random_uuid(),
          lease_generation = l.lease_generation + 1,
          lease_expires_at = pg_catalog.clock_timestamp() + interval '10 minutes',
          lease_status = 'claimed',
          batch_id = v_batch.id,
          claimed_at = pg_catalog.clock_timestamp(),
          updated_at = pg_catalog.clock_timestamp(),
          last_error = NULL
      WHERE l.target_user_id = v_batch.target_user_id
      RETURNING l.* INTO v_lease;

      target_user_id := v_batch.target_user_id;
      batch_id := v_batch.id;
      scheduled_for := v_batch.scheduled_for;
      work_status := 'deleting';
      lease_token := v_lease.lease_token;
      lease_generation := v_lease.lease_generation;
      lease_expires_at := v_lease.lease_expires_at;
      RETURN NEXT;
      v_claimed := v_claimed + 1;
    END LOOP;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.renew_account_deletion_lease(
  p_user_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  UPDATE public.account_deletion_work_leases AS l
  SET lease_expires_at = pg_catalog.clock_timestamp() + interval '10 minutes',
      updated_at = pg_catalog.statement_timestamp()
  WHERE l.target_user_id = p_user_id
    AND l.lease_token = p_lease_token
    AND l.lease_generation = p_lease_generation
    AND l.lease_status = 'claimed'
    AND l.lease_expires_at > pg_catalog.clock_timestamp();
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.prepare_account_deletion_leased(
  p_user_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint
)
RETURNS TABLE(batch_id uuid, target_user_id uuid, batch_status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_requested_at timestamptz;
  v_scheduled_for timestamptz;
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_id uuid;
  v_batch_status text;
BEGIN
  -- Canonical lock order: request -> lease -> batch.
  SELECT q.requested_at, q.scheduled_for
    INTO v_requested_at, v_scheduled_for
  FROM public.account_deletion_requests AS q
  WHERE q.user_id = p_user_id
    AND q.scheduled_for <= pg_catalog.statement_timestamp()
  FOR UPDATE;

  IF FOUND THEN
    SELECT l.* INTO v_lease
    FROM public.account_deletion_work_leases AS l
    WHERE l.target_user_id = p_user_id
    FOR UPDATE;
    IF NOT FOUND OR v_lease.requested_at IS DISTINCT FROM v_requested_at
       OR v_lease.scheduled_for IS DISTINCT FROM v_scheduled_for
       OR v_lease.lease_token IS DISTINCT FROM p_lease_token
       OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
       OR v_lease.lease_status <> 'claimed'
       OR v_lease.lease_expires_at <= pg_catalog.clock_timestamp() THEN
      RAISE EXCEPTION 'account_deletion_lease_lost' USING ERRCODE = '55000';
    END IF;

    SELECT b.id INTO v_batch_id
    FROM public.account_deletion_archive_batches AS b
    WHERE b.target_user_id = p_user_id
      AND b.requested_at = v_requested_at
      AND b.scheduled_for = v_scheduled_for
      AND b.status NOT IN ('completed', 'cancelled')
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;

    -- This existing SECURITY DEFINER routine performs the verified archive and
    -- relational prepare in one transaction. Its direct service_role EXECUTE is
    -- revoked below; only this fenced wrapper remains callable by the worker.
    RETURN QUERY
      SELECT p.batch_id, p.target_user_id, p.batch_status
      FROM public.prepare_account_deletion(p_user_id) AS p;
    UPDATE public.account_deletion_work_leases AS l
    SET batch_id = (SELECT b.id FROM public.account_deletion_archive_batches AS b
                    WHERE b.target_user_id = p_user_id
                      AND b.requested_at = v_requested_at
                      AND b.scheduled_for = v_scheduled_for
                    ORDER BY b.created_at DESC LIMIT 1),
        updated_at = pg_catalog.statement_timestamp()
    WHERE l.target_user_id = p_user_id
      AND l.lease_token = p_lease_token
      AND l.lease_generation = p_lease_generation;
    RETURN;
  END IF;

  -- Recovery after prepare committed and cascaded the request row.
  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND OR v_lease.lease_token IS DISTINCT FROM p_lease_token
     OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
     OR v_lease.lease_status <> 'claimed'
     OR v_lease.lease_expires_at <= pg_catalog.clock_timestamp()
     OR v_lease.batch_id IS NULL THEN
    RAISE EXCEPTION 'account_deletion_lease_lost' USING ERRCODE = '55000';
  END IF;

  SELECT b.id, b.status INTO v_batch_id, v_batch_status
  FROM public.account_deletion_archive_batches AS b
  WHERE b.id = v_lease.batch_id
    AND b.target_user_id = p_user_id
    AND b.requested_at = v_lease.requested_at
    AND b.scheduled_for = v_lease.scheduled_for
  FOR UPDATE;

  IF NOT FOUND OR v_batch_status NOT IN ('deleting', 'completed') THEN
    RAISE EXCEPTION 'account_deletion_recovery_batch_not_ready';
  END IF;
  RETURN QUERY SELECT v_batch_id, p_user_id, v_batch_status;
END;
$function$;

CREATE OR REPLACE FUNCTION public.finalize_account_deletion_leased(
  p_user_id uuid,
  p_batch_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_user uuid;
BEGIN
  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND OR v_lease.lease_token IS DISTINCT FROM p_lease_token
     OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
     OR v_lease.lease_status <> 'claimed'
     OR v_lease.lease_expires_at <= pg_catalog.clock_timestamp()
     OR v_lease.batch_id IS DISTINCT FROM p_batch_id THEN
    RAISE EXCEPTION 'account_deletion_lease_lost' USING ERRCODE = '55000';
  END IF;

  SELECT b.target_user_id INTO v_batch_user
  FROM public.account_deletion_archive_batches AS b
  WHERE b.id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND OR v_batch_user IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'account_deletion_batch_lease_mismatch';
  END IF;

  IF NOT public.finalize_account_deletion(p_batch_id) THEN
    RETURN false;
  END IF;

  UPDATE public.account_deletion_work_leases AS l
  SET lease_status = 'completed',
      lease_expires_at = pg_catalog.clock_timestamp(),
      updated_at = pg_catalog.statement_timestamp(),
      last_error = NULL
  WHERE l.target_user_id = p_user_id
    AND l.lease_token = p_lease_token
    AND l.lease_generation = p_lease_generation;
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_account_deletion_failure_leased(
  p_user_id uuid,
  p_batch_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_lease public.account_deletion_work_leases%ROWTYPE;
BEGIN
  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND OR v_lease.lease_token IS DISTINCT FROM p_lease_token
     OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
     OR v_lease.lease_status <> 'claimed'
     OR v_lease.lease_expires_at <= pg_catalog.clock_timestamp()
     OR v_lease.batch_id IS DISTINCT FROM p_batch_id THEN
    RETURN false;
  END IF;

  -- Lock and validate the associated batch before writing either failure record.
  IF p_batch_id IS NOT NULL THEN
    PERFORM 1
    FROM public.account_deletion_archive_batches AS b
    WHERE b.id = p_batch_id
      AND b.target_user_id = p_user_id
      AND b.status IN ('archived', 'deleting', 'failed')
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN false;
    END IF;
  END IF;

  UPDATE public.account_deletion_work_leases AS l
  SET attempt_count = l.attempt_count + 1,
      last_error = pg_catalog.left(
        coalesce(nullif(p_error_code, ''), 'worker_error'), 300
      ),
      updated_at = pg_catalog.statement_timestamp()
  WHERE l.target_user_id = p_user_id
    AND l.lease_token = p_lease_token
    AND l.lease_generation = p_lease_generation;

  IF p_batch_id IS NOT NULL THEN
    UPDATE public.account_deletion_archive_batches AS b
    SET last_error = pg_catalog.left(
          coalesce(nullif(p_error_code, ''), 'worker_error'), 300
        ),
        updated_at = pg_catalog.statement_timestamp(),
        attempt_count = b.attempt_count + 1
    WHERE b.id = p_batch_id
      AND b.target_user_id = p_user_id
      AND b.status IN ('archived', 'deleting', 'failed');
  END IF;
  RETURN true;
END;
$function$;

-- Cancellation serializes with claim using request -> lease -> batch lock order.
CREATE OR REPLACE FUNCTION public.cancel_account_deletion()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_requested_at timestamptz;
  v_scheduled_for timestamptz;
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION '請先登入';
  END IF;

  SELECT r.requested_at, r.scheduled_for
    INTO v_requested_at, v_scheduled_for
  FROM public.account_deletion_requests AS r
  WHERE r.user_id = v_user_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到待處理的刪除申請';
  END IF;

  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = v_user_id
  FOR UPDATE;

  IF FOUND AND v_lease.lease_status = 'claimed'
     AND (v_lease.lease_expires_at > pg_catalog.clock_timestamp() OR v_lease.batch_id IS NOT NULL) THEN
    RAISE EXCEPTION '刪除處理已由背景工作領取，無法取消';
  END IF;

  SELECT b.id INTO v_batch_id
  FROM public.account_deletion_archive_batches AS b
  WHERE b.target_user_id = v_user_id
    AND b.requested_at = v_requested_at
    AND b.scheduled_for = v_scheduled_for
  ORDER BY b.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    RAISE EXCEPTION '刪除處理已開始，無法透過此功能復原；請交由管理程序檢查';
  END IF;

  DELETE FROM public.account_deletion_requests AS r
  WHERE r.user_id = v_user_id
    AND r.requested_at = v_requested_at
    AND r.scheduled_for = v_scheduled_for;
  IF NOT FOUND THEN
    RAISE EXCEPTION '刪除申請狀態已變更，請重新查詢帳號狀態';
  END IF;

  IF v_lease.target_user_id IS NOT NULL THEN
    UPDATE public.account_deletion_work_leases AS l
    SET lease_status = 'cancelled',
        lease_expires_at = pg_catalog.clock_timestamp(),
        updated_at = pg_catalog.clock_timestamp(),
        last_error = NULL
    WHERE l.target_user_id = v_user_id
      AND l.requested_at = v_requested_at
      AND l.scheduled_for = v_scheduled_for;
  END IF;
END;
$function$;

-- Remove all un-fenced service-role entry points. The SECURITY DEFINER wrappers
-- above call the original routines as their owner (postgres) within one transaction.
REVOKE ALL ON FUNCTION public.get_account_deletion_work_items() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.archive_account_deletion_data(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.prepare_account_deletion(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finalize_account_deletion(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_account_deletion_failure(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.claim_account_deletion_work_items(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.renew_account_deletion_lease(uuid, uuid, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prepare_account_deletion_leased(uuid, uuid, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_account_deletion_leased(uuid, uuid, uuid, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_account_deletion_failure_leased(uuid, uuid, uuid, bigint, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.claim_account_deletion_work_items(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.renew_account_deletion_lease(uuid, uuid, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.prepare_account_deletion_leased(uuid, uuid, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_account_deletion_leased(uuid, uuid, uuid, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_account_deletion_failure_leased(uuid, uuid, uuid, bigint, text) TO service_role;

-- Keep the player-facing cancellation RPC authenticated-only.
REVOKE ALL ON FUNCTION public.cancel_account_deletion() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_account_deletion() TO authenticated;
