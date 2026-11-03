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

-- DRAFT ONLY — PR #200 follow-up for sync_character_chat_snapshot.
-- Do not move into migrations or apply to hosted DB until local replay and
-- authenticated race fixtures pass.
--
-- Defect confirmed in live test DB on 2026-11-02:
-- The current SECURITY DEFINER function updates chat_group_members and
-- chat_group_messages by character_id without locking the parent chat_groups
-- row and without excluding deleted groups. This permits metadata mutation
-- after chat deletion even though authenticated RLS blocks ordinary writes.
--
-- Lock parents first, in deterministic order, then update only active parents.
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

-- Required transaction/race fixtures before this draft can be promoted:
-- 1. sync obtains parent lock first: snapshot update commits, then delete runs.
-- 2. delete obtains parent lock first: sync waits, then updates zero rows for
--    that deleted parent.
-- 3. Deleted parent members/messages remain byte-for-byte unchanged after sync.
-- 4. Active parent members/messages still receive the current character fields.
-- 5. Non-author, unauthenticated, and account-deletion-pending callers fail.
-- 6. Verify function owner, EXECUTE ACL, search_path, and SECURITY DEFINER
--    dependencies remain unchanged; no anon/PUBLIC execute path is introduced.
