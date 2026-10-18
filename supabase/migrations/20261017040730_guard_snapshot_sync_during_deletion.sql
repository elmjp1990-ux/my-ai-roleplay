-- Block pending-deletion accounts from mutating other users' chat snapshots.
-- Test environment only; reconcile migration history before applying elsewhere.
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required.' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.account_deletion_requests AS r
    WHERE r.user_id = auth.uid()
  ) THEN
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
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', v_visibility,
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    ),
    updated_at = now()
  WHERE cs.character_id = p_character_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;
