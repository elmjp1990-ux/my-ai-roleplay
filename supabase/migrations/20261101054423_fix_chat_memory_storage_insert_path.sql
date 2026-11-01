-- Correct the full UUID shape in the chat-memory Storage upload path check.
DROP POLICY IF EXISTS memory_photo_objects_insert_owner ON storage.objects;
CREATE POLICY memory_photo_objects_insert_owner
ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id='personax-memory-photos'
  AND public.account_is_active()
  AND split_part(name,'/',1)=(SELECT auth.uid())::text
  AND name ~* (
    '^' || (SELECT auth.uid())::text ||
    '/(single|group)/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
    '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$'
  )
  AND (
    (
      split_part(name,'/',2)='single'
      AND EXISTS (
        SELECT 1 FROM public.chat_sessions s
        WHERE s.id::text=split_part(objects.name,'/',3)
          AND s.user_id=(SELECT auth.uid())
          AND s.deleted_at IS NULL
      )
    )
    OR
    (
      split_part(name,'/',2)='group'
      AND EXISTS (
        SELECT 1 FROM public.chat_groups g
        WHERE g.id::text=split_part(objects.name,'/',3)
          AND g.owner_id=(SELECT auth.uid())
          AND g.archived_at IS NULL
          AND g.deleted_at IS NULL
      )
    )
  )
);
