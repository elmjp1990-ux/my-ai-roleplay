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
  WHERE c.id = p_character_id;

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
