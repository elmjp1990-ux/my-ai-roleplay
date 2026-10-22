-- SECURITY: fix the group-memory photo Storage SELECT policy path check.
-- The group branch previously compared the group UUID to segment 3 of g.name,
-- rather than segment 3 of storage.objects.name. This incorrectly denied reads
-- for valid group-owned memory photos. Keep the bucket and owner checks intact.
DROP POLICY IF EXISTS memory_photo_objects_select_owner ON storage.objects;

CREATE POLICY memory_photo_objects_select_owner
ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'personax-memory-photos'
  AND split_part(name, '/', 1) = (SELECT auth.uid())::text
  AND (
    (
      split_part(name, '/', 2) = 'single'
      AND EXISTS (
        SELECT 1
        FROM public.chat_sessions s
        WHERE s.id::text = split_part(name, '/', 3)
          AND s.user_id = (SELECT auth.uid())
          AND s.deleted_at IS NULL
      )
    )
    OR
    (
      split_part(name, '/', 2) = 'group'
      AND EXISTS (
        SELECT 1
        FROM public.chat_groups g
        WHERE g.id::text = split_part(name, '/', 3)
          AND g.owner_id = (SELECT auth.uid())
          AND g.archived_at IS NULL
      )
    )
  )
);
