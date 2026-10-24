-- Fix permissive account guard: RLS permissive policies are OR-combined.
-- A restrictive guard requires active account status without bypassing owner/visibility/age policies.
DROP POLICY IF EXISTS "account_must_be_active" ON public.characters;
CREATE POLICY "account_must_be_active"
ON public.characters
AS RESTRICTIVE
FOR ALL
TO authenticated
USING (public.account_is_active())
WITH CHECK (public.account_is_active());

-- Public characters may be viewed anonymously, so eligible public videos must be readable by anon too.
DROP POLICY IF EXISTS "Character video visible to eligible viewers" ON storage.objects;
CREATE POLICY "Character video visible to eligible viewers"
ON storage.objects
FOR SELECT
TO anon, authenticated
USING (
  bucket_id='character-avatar-videos'
  AND (
    (SELECT auth.uid()) IS NOT NULL
    AND (storage.foldername(name))[1]=(SELECT auth.uid())::text
    OR EXISTS (
      SELECT 1 FROM public.characters c
      WHERE c.avatar_video_path=storage.objects.name
        AND c.visibility='public'
        AND c.deleted_at IS NULL
        AND (c.is_nsfw IS NOT TRUE OR ((SELECT auth.uid()) IS NOT NULL AND public.current_user_is_adult()))
    )
  )
);
