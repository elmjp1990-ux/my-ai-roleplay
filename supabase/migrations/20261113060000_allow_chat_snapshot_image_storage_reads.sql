-- Permit exact historical portrait paths embedded in an owned, undeleted chat snapshot.
-- This extends the narrow read helper introduced by
-- 20261113050000_allow_existing_chat_character_media_read.
-- It does not grant bucket listing, discovery, upload, update, or delete access.

CREATE OR REPLACE FUNCTION private.can_read_character_asset(
  p_bucket_id text,
  p_object_name text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT auth.uid() IS NOT NULL
    AND public.account_is_active() IS TRUE
    AND CASE p_bucket_id
      WHEN 'character-illustrations' THEN (
        EXISTS (
          SELECT 1
          FROM public.character_illustrations AS ci
          WHERE ci.storage_path = p_object_name
            AND private.user_has_existing_character_session(ci.character_id)
        )
        OR EXISTS (
          SELECT 1
          FROM public.chat_sessions AS s
          JOIN public.characters AS c
            ON c.id = s.character_id
          WHERE s.user_id = auth.uid()
            AND s.deleted_at IS NULL
            AND s.character_snapshot->>'imagePath' = p_object_name
            AND split_part(p_object_name, '/', 1) = c.author_id::text
            AND split_part(p_object_name, '/', 2) = s.character_id::text
            AND p_object_name ~* (
              '^' || c.author_id::text || '/' || s.character_id::text ||
              '/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$'
            )
        )
      )
      ELSE false
    END;
$function$;

COMMENT ON FUNCTION private.can_read_character_asset(text, text) IS
  'Allows exact character illustration metadata paths for existing chats and exact historical image paths stored in an owned undeleted chat snapshot; no general bucket access.';
