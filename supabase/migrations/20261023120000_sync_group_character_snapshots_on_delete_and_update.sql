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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF NOT public.account_is_active() THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  SELECT c.author_id, c.first_published_at, c.deleted_at
    INTO v_author_id, v_first_published_at, v_deleted_at
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

  v_deleted_at := now();

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
    jsonb_build_object('authorId', v_author_id, 'visibility', 'private',
      'firstPublishedAt', v_first_published_at, 'deletedAt', v_deleted_at),
    updated_at = now()
  WHERE cs.character_id = p_character_id;

  UPDATE public.chat_group_members gm
  SET character_snapshot = COALESCE(gm.character_snapshot, '{}'::jsonb) ||
    jsonb_build_object('authorId', v_author_id, 'visibility', 'private',
      'firstPublishedAt', v_first_published_at, 'deletedAt', v_deleted_at)
  WHERE gm.character_id = p_character_id;

  UPDATE public.chat_group_messages gm
  SET speaker_snapshot = COALESCE(gm.speaker_snapshot, '{}'::jsonb) ||
    jsonb_build_object('authorId', v_author_id, 'visibility', 'private',
      'firstPublishedAt', v_first_published_at, 'deletedAt', v_deleted_at)
  WHERE gm.character_id = p_character_id;

  RETURN v_deleted_at;
END;
$function$;

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

  UPDATE public.chat_sessions cs
  SET character_snapshot = COALESCE(cs.character_snapshot, '{}'::jsonb) ||
    jsonb_build_object('authorId', v_author_id, 'visibility', v_visibility,
      'firstPublishedAt', v_first_published_at, 'deletedAt', v_deleted_at),
    updated_at = now()
  WHERE cs.character_id = p_character_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_count := v_count + v_rows;

  UPDATE public.chat_group_members gm
  SET character_snapshot = COALESCE(gm.character_snapshot, '{}'::jsonb) ||
    jsonb_build_object('authorId', v_author_id, 'visibility', v_visibility,
      'firstPublishedAt', v_first_published_at, 'deletedAt', v_deleted_at)
  WHERE gm.character_id = p_character_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_count := v_count + v_rows;

  UPDATE public.chat_group_messages gm
  SET speaker_snapshot = COALESCE(gm.speaker_snapshot, '{}'::jsonb) ||
    jsonb_build_object('authorId', v_author_id, 'visibility', v_visibility,
      'firstPublishedAt', v_first_published_at, 'deletedAt', v_deleted_at)
  WHERE gm.character_id = p_character_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_count := v_count + v_rows;

  RETURN v_count;
END;
$function$;
