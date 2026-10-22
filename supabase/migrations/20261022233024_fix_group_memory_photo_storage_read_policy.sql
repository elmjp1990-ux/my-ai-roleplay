-- SECURITY: fix the group-memory photo Storage SELECT policy path check.
-- Qualify storage.objects.name inside EXISTS subqueries; otherwise the unqualified
-- name can resolve to the inner table's name column instead of the Storage path.
-- Keep the bucket and owner checks intact.
DROP POLICY IF EXISTS memory_photo_objects_select_owner ON storage.objects;

CREATE POLICY memory_photo_objects_select_owner
ON storage.objects
FOR SELECT TO authenticated
USING (
  storage.objects.bucket_id = 'personax-memory-photos'
  AND split_part(storage.objects.name, '/', 1) = (SELECT auth.uid())::text
  AND (
    (
      split_part(storage.objects.name, '/', 2) = 'single'
      AND EXISTS (
        SELECT 1
        FROM public.chat_sessions s
        WHERE s.id::text = split_part(storage.objects.name, '/', 3)
          AND s.user_id = (SELECT auth.uid())
          AND s.deleted_at IS NULL
      )
    )
    OR
    (
      split_part(storage.objects.name, '/', 2) = 'group'
      AND EXISTS (
        SELECT 1
        FROM public.chat_groups g
        WHERE g.id::text = split_part(storage.objects.name, '/', 3)
          AND g.owner_id = (SELECT auth.uid())
          AND g.archived_at IS NULL
      )
    )
  )
);
