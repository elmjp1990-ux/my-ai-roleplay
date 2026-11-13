-- Allow owners of an existing, undeleted chat to read only that character's
-- private illustration assets after the character is hidden or soft-deleted.
--
-- This is a narrow read path required before moving legacy chat portrait data
-- from JSON snapshots into the private character-illustrations Storage bucket.
-- It does not grant discovery, new-chat, upload, update, or delete permissions.
-- It does not change character visibility or any existing write policy.

CREATE OR REPLACE FUNCTION private.user_has_existing_character_session(
  p_character_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
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
          AND g.deleted_at IS NULL
      )
    );
$function$;

REVOKE ALL ON FUNCTION private.user_has_existing_character_session(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.user_has_existing_character_session(uuid)
  TO authenticated;

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
    AND CASE p_bucket_id
      WHEN 'character-illustrations' THEN EXISTS (
        SELECT 1
        FROM public.character_illustrations AS ci
        WHERE ci.storage_path = p_object_name
          AND private.user_has_existing_character_session(ci.character_id)
      )
      ELSE false
    END;
$function$;

REVOKE ALL ON FUNCTION private.can_read_character_asset(text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_read_character_asset(text, text)
  TO authenticated;

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
  USING (
    bucket_id = 'character-illustrations'
    AND private.can_read_character_asset(bucket_id, name)
  );

COMMENT ON FUNCTION private.user_has_existing_character_session(uuid) IS
  'True only for an active authenticated account that owns an undeleted single or group chat containing this character; used solely for retained chat media reads.';
COMMENT ON FUNCTION private.can_read_character_asset(text, text) IS
  'Allows exact character-illustrations Storage paths referenced by illustration metadata for an existing chat; never grants general bucket access.';
