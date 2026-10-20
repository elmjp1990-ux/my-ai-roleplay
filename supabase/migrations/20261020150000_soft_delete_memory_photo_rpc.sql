-- MEMORY-ALBUM-01: owner-checked RPC for soft-deleting a memory photo.
-- The browser must not UPDATE status/deleted_at directly because RLS WITH CHECK
-- can reject the new row after soft deletion. This function deliberately verifies
-- the authenticated owner before changing any metadata.
CREATE OR REPLACE FUNCTION public.soft_delete_chat_memory_photo(p_photo_id uuid)
RETURNS TABLE(storage_path text, chat_type text, session_id uuid, group_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  UPDATE public.chat_memory_photos AS p
     SET status = 'deleting',
         deleted_at = pg_catalog.now()
   WHERE p.id = p_photo_id
     AND p.owner_id = v_uid
     AND p.deleted_at IS NULL
  RETURNING p.storage_path, p.chat_type, p.session_id, p.group_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'photo not found or not owned by current user' USING ERRCODE = '42501';
  END IF;

  -- If the photo is the active group background, clear it without selecting a replacement.
  UPDATE public.chat_groups AS g
     SET background_mode = 'none',
         background_memory_photo_id = NULL,
         updated_at = pg_catalog.now()
   WHERE g.background_memory_photo_id = p_photo_id
     AND g.owner_id = v_uid;
END;
$function$;

REVOKE ALL ON FUNCTION public.soft_delete_chat_memory_photo(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.soft_delete_chat_memory_photo(uuid) TO authenticated;
