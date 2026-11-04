
CREATE OR REPLACE FUNCTION public.delete_chat_group_with_related_data(p_group_id uuid)
RETURNS TABLE(storage_path text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_owner_id uuid;
  v_paths text[] := ARRAY[]::text[];
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

  SELECT g.owner_id INTO v_owner_id
  FROM public.chat_groups g
  WHERE g.id = p_group_id
  FOR UPDATE;

  IF NOT FOUND OR v_owner_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'group_not_found_or_not_owned' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(pg_catalog.array_agg(p.storage_path), ARRAY[]::text[])
    INTO v_paths
  FROM public.chat_memory_photos p
  WHERE p.group_id = p_group_id
    AND p.owner_id = v_user_id
    AND p.storage_path IS NOT NULL;

  UPDATE public.chat_groups
     SET background_mode = 'none',
         background_memory_photo_id = NULL,
         updated_at = pg_catalog.now()
   WHERE id = p_group_id AND owner_id = v_user_id;

  DELETE FROM public.chat_group_messages WHERE group_id = p_group_id;
  DELETE FROM public.chat_group_members WHERE group_id = p_group_id;
  DELETE FROM public.chat_group_turns WHERE group_id = p_group_id;
  DELETE FROM public.chat_group_scenes WHERE group_id = p_group_id;
  DELETE FROM public.chat_group_diary
   WHERE group_id = p_group_id AND owner_id = v_user_id;
  DELETE FROM public.chat_group_memory_photos
   WHERE group_id = p_group_id AND owner_id = v_user_id;
  DELETE FROM public.chat_memory_photos
   WHERE group_id = p_group_id AND owner_id = v_user_id;
  DELETE FROM public.chat_groups
   WHERE id = p_group_id AND owner_id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'group_delete_failed' USING ERRCODE = '40001';
  END IF;

  RETURN QUERY SELECT pg_catalog.unnest(v_paths);
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_chat_group_with_related_data(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_chat_group_with_related_data(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_chat_group_with_related_data(uuid) TO authenticated;
