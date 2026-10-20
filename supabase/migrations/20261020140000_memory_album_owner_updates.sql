-- Allow the authenticated owner to rename or soft-delete their own album photo.
-- The chat/group ownership checks remain enforced by the existing SELECT policy and the immutable owner/chat fields.
DROP POLICY IF EXISTS memory_photos_update_owner ON public.chat_memory_photos;
CREATE POLICY memory_photos_update_owner
ON public.chat_memory_photos
FOR UPDATE TO authenticated
USING (owner_id = (SELECT auth.uid()))
WITH CHECK (
  owner_id = (SELECT auth.uid())
  AND chat_type IN ('single','group')
  AND expires_at > created_at
);
