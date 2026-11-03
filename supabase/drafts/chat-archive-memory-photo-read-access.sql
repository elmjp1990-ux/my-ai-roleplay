-- DRAFT ONLY — NOT AN ACTIVE MIGRATION.
-- Preserve memory-photo reads for manually archived groups.
-- Do not execute against hosted Supabase before disposable local replay.
--
-- chat_groups.archived_at only hides a group from the active list. It is not deletion.
-- A group marked deleted_at is immediately inaccessible and enters the 30-day purge flow.
-- The existing memory-photo SELECT policies incorrectly require archived_at IS NULL,
-- which breaks photo access for a manually archived group even though its history remains.

DROP POLICY IF EXISTS memory_photos_select_owner
  ON public.chat_memory_photos;
CREATE POLICY memory_photos_select_owner
  ON public.chat_memory_photos
  FOR SELECT TO authenticated
  USING (
    owner_id = (SELECT auth.uid())
    AND deleted_at IS NULL
    AND (
      (
        chat_type = 'single'
        AND EXISTS (
          SELECT 1
          FROM public.chat_sessions AS s
          WHERE s.id = chat_memory_photos.session_id
            AND s.user_id = (SELECT auth.uid())
            AND s.deleted_at IS NULL
        )
      )
      OR
      (
        chat_type = 'group'
        AND EXISTS (
          SELECT 1
          FROM public.chat_groups AS g
          WHERE g.id = chat_memory_photos.group_id
            AND g.owner_id = (SELECT auth.uid())
            AND g.deleted_at IS NULL
            -- Intentionally no archived_at predicate.
        )
      )
    )
  );

CREATE OR REPLACE FUNCTION private.can_read_chat_memory_photo_object(p_storage_path text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    p_storage_path IS NOT NULL
    AND auth.uid() IS NOT NULL
    AND pg_catalog.split_part(p_storage_path, '/', 1) = auth.uid()::text
    AND p_storage_path ~* (
      '^' || auth.uid()::text ||
      '/(single|group)/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
      '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$'
    )
    AND EXISTS (
      SELECT 1
      FROM public.chat_memory_photos AS p
      WHERE p.storage_path = p_storage_path
        AND p.owner_id = auth.uid()
        AND p.deleted_at IS NULL
        AND (
          (
            p.chat_type = 'single'
            AND EXISTS (
              SELECT 1 FROM public.chat_sessions AS s
              WHERE s.id = p.session_id
                AND s.user_id = auth.uid()
                AND s.deleted_at IS NULL
            )
          )
          OR
          (
            p.chat_type = 'group'
            AND EXISTS (
              SELECT 1 FROM public.chat_groups AS g
              WHERE g.id = p.group_id
                AND g.owner_id = auth.uid()
                AND g.deleted_at IS NULL
            )
          )
        )
    );
$function$;

REVOKE ALL ON FUNCTION private.can_read_chat_memory_photo_object(text) FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT EXECUTE ON FUNCTION private.can_read_chat_memory_photo_object(text) TO authenticated;

DROP POLICY IF EXISTS memory_photo_objects_select_owner
  ON storage.objects;
CREATE POLICY memory_photo_objects_select_owner
  ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'personax-memory-photos'
    AND private.can_read_chat_memory_photo_object(name)
  );
-- No INSERT, UPDATE, DELETE, purge, or retention behavior is changed here.
-- Deleted chats remain inaccessible immediately; backend purge remains governed
-- by chat_deletion_jobs.purge_after and the existing deletion worker.
