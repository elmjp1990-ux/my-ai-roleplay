-- Freeze direct character-video Storage writes while an account deletion request is pending.
-- Keep owner-scoped deletion available; only upload and update create/change assets.
DROP POLICY IF EXISTS "Character video owner upload" ON storage.objects;
CREATE POLICY "Character video owner upload"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'character-avatar-videos'
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
  AND public.account_is_active()
);

DROP POLICY IF EXISTS "Character video owner update" ON storage.objects;
CREATE POLICY "Character video owner update"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'character-avatar-videos'
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
  AND public.account_is_active()
)
WITH CHECK (
  bucket_id = 'character-avatar-videos'
  AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
  AND public.account_is_active()
);
