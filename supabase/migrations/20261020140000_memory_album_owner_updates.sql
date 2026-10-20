-- Allow an authenticated owner to rename or soft-delete a photo without moving it to another chat.
DROP POLICY IF EXISTS memory_photos_update_owner ON public.chat_memory_photos;
CREATE POLICY memory_photos_update_owner
ON public.chat_memory_photos
FOR UPDATE TO authenticated
USING (
  owner_id = (SELECT auth.uid())
  AND (
    (chat_type = 'single' AND EXISTS (
      SELECT 1 FROM public.chat_sessions s
      WHERE s.id = chat_memory_photos.session_id
        AND s.user_id = (SELECT auth.uid()) AND s.deleted_at IS NULL
    ))
    OR
    (chat_type = 'group' AND EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = chat_memory_photos.group_id
        AND g.owner_id = (SELECT auth.uid()) AND g.archived_at IS NULL
    ))
  )
)
WITH CHECK (
  owner_id = (SELECT auth.uid())
  AND (
    (chat_type = 'single' AND EXISTS (
      SELECT 1 FROM public.chat_sessions s
      WHERE s.id = chat_memory_photos.session_id
        AND s.user_id = (SELECT auth.uid()) AND s.deleted_at IS NULL
    ))
    OR
    (chat_type = 'group' AND EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = chat_memory_photos.group_id
        AND g.owner_id = (SELECT auth.uid()) AND g.archived_at IS NULL
    ))
  )
);
