-- Keep private character portraits readable only by players who already own
-- an active single/group chat whose trusted snapshot names this exact Storage path.
-- This does not grant folder access or make soft-deleted characters discoverable.

DROP POLICY IF EXISTS "Character illustrations visible to eligible viewers" ON storage.objects;

CREATE POLICY "Character illustrations visible to eligible viewers"
  ON storage.objects
  FOR SELECT
  TO anon, authenticated
  USING (
    bucket_id = 'character-illustrations'
    AND (
      -- The author may continue to read their own character assets.
      (
        split_part(objects.name, '/', 1) = (SELECT auth.uid())::text
        AND EXISTS (
          SELECT 1
          FROM public.characters c
          WHERE c.id::text = split_part(objects.name, '/', 2)
            AND c.author_id = (SELECT auth.uid())
        )
      )
      -- Public eligible characters remain readable as before.
      OR EXISTS (
        SELECT 1
        FROM public.character_illustrations ci
        JOIN public.characters c ON c.id = ci.character_id
        WHERE ci.storage_path = objects.name
          AND c.visibility = 'public'
          AND c.deleted_at IS NULL
          AND (
            c.is_nsfw IS NOT TRUE
            OR ((SELECT auth.uid()) IS NOT NULL AND private.current_user_is_adult())
          )
      )
      -- Existing single Story / Encounter chats may read only the exact
      -- primary portrait path captured when their session was created.
      OR (
        (SELECT auth.uid()) IS NOT NULL
        AND public.account_is_active()
        AND EXISTS (
          SELECT 1
          FROM public.chat_sessions cs
          WHERE cs.user_id = (SELECT auth.uid())
            AND cs.deleted_at IS NULL
            AND cs.character_id::text = split_part(objects.name, '/', 2)
            AND cs.character_snapshot->>'imagePath' = objects.name
        )
      )
      -- Existing group chats receive the same narrow access, bound to the
      -- exact member snapshot path and the group owner.
      OR (
        (SELECT auth.uid()) IS NOT NULL
        AND public.account_is_active()
        AND EXISTS (
          SELECT 1
          FROM public.chat_group_members gm
          JOIN public.chat_groups g ON g.id = gm.group_id
          WHERE g.owner_id = (SELECT auth.uid())
            AND g.deleted_at IS NULL
            AND gm.character_id::text = split_part(objects.name, '/', 2)
            AND gm.character_snapshot->>'imagePath' = objects.name
        )
      )
    )
  );
