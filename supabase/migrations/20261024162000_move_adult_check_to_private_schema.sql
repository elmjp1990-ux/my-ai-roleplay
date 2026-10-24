CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO anon, authenticated;

CREATE OR REPLACE FUNCTION private.current_user_is_adult()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles AS p
    WHERE p.id = (SELECT auth.uid())
      AND p.birthdate IS NOT NULL
      AND p.birthdate <= (CURRENT_DATE - INTERVAL '18 years')::date
  );
$$;
REVOKE ALL ON FUNCTION private.current_user_is_adult() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.current_user_is_adult() TO anon, authenticated;

DROP POLICY IF EXISTS "characters_hide_soft_deleted_from_non_owner" ON public.characters;
CREATE POLICY "characters_hide_soft_deleted_from_non_owner"
ON public.characters
FOR SELECT TO anon, authenticated
USING (
  author_id = (SELECT auth.uid())
  OR (
    visibility = 'public'
    AND deleted_at IS NULL
    AND (
      is_nsfw IS NOT TRUE
      OR ((SELECT auth.uid()) IS NOT NULL AND private.current_user_is_adult())
    )
  )
);

DROP POLICY IF EXISTS "公開檢視公開且未下架的角色" ON public.characters;
CREATE POLICY "公開檢視公開且未下架的角色"
ON public.characters
FOR SELECT TO anon, authenticated
USING (
  visibility = 'public'
  AND deleted_at IS NULL
  AND (
    is_nsfw IS NOT TRUE
    OR ((SELECT auth.uid()) IS NOT NULL AND private.current_user_is_adult())
  )
);

DROP POLICY IF EXISTS "Character video visible to eligible viewers" ON storage.objects;
CREATE POLICY "Character video visible to eligible viewers"
ON storage.objects
FOR SELECT TO anon, authenticated
USING (
  bucket_id='character-avatar-videos'
  AND (
    ((SELECT auth.uid()) IS NOT NULL AND (storage.foldername(name))[1]=(SELECT auth.uid())::text)
    OR EXISTS (
      SELECT 1 FROM public.characters c
      WHERE c.avatar_video_path=storage.objects.name
        AND c.visibility='public'
        AND c.deleted_at IS NULL
        AND (c.is_nsfw IS NOT TRUE OR ((SELECT auth.uid()) IS NOT NULL AND private.current_user_is_adult()))
    )
  )
);

DROP FUNCTION IF EXISTS public.current_user_is_adult();
