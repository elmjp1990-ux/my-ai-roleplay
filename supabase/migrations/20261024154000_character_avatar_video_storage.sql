ALTER TABLE public.characters
  ADD COLUMN IF NOT EXISTS avatar_video_path text;

INSERT INTO storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
VALUES ('character-avatar-videos','character-avatar-videos',false,15728640,ARRAY['video/mp4','video/webm','video/quicktime'])
ON CONFLICT (id) DO UPDATE SET
  public=false,
  file_size_limit=15728640,
  allowed_mime_types=ARRAY['video/mp4','video/webm','video/quicktime'];

DROP POLICY IF EXISTS "Character video owner upload" ON storage.objects;
CREATE POLICY "Character video owner upload" ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id='character-avatar-videos'
  AND (storage.foldername(name))[1]=(SELECT auth.uid())::text
);

DROP POLICY IF EXISTS "Character video owner update" ON storage.objects;
CREATE POLICY "Character video owner update" ON storage.objects
FOR UPDATE TO authenticated
USING (
  bucket_id='character-avatar-videos'
  AND (storage.foldername(name))[1]=(SELECT auth.uid())::text
)
WITH CHECK (
  bucket_id='character-avatar-videos'
  AND (storage.foldername(name))[1]=(SELECT auth.uid())::text
);

DROP POLICY IF EXISTS "Character video owner delete" ON storage.objects;
CREATE POLICY "Character video owner delete" ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id='character-avatar-videos'
  AND (storage.foldername(name))[1]=(SELECT auth.uid())::text
);

DROP POLICY IF EXISTS "Character video visible to eligible viewers" ON storage.objects;
CREATE POLICY "Character video visible to eligible viewers" ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id='character-avatar-videos'
  AND (
    (storage.foldername(name))[1]=(SELECT auth.uid())::text
    OR EXISTS (
      SELECT 1 FROM public.characters c
      WHERE c.avatar_video_path=storage.objects.name
        AND c.visibility='public'
        AND c.deleted_at IS NULL
        AND (c.is_nsfw IS NOT TRUE OR public.current_user_is_adult())
    )
  )
);

COMMENT ON COLUMN public.characters.avatar_video_path IS
  'Path to a private Storage video. Public signed URL access is limited by Storage RLS and character visibility/age policy.';
