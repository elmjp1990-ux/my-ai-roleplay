-- Freeze character asset mutation through Storage API as soon as an account
-- deletion request exists. Table RLS alone cannot protect storage.objects.
-- Keep SELECT policies intact so eligible existing viewers can continue to
-- read preserved public assets and prior chat snapshots.

DROP POLICY IF EXISTS "Character illustration owner update" ON storage.objects;
CREATE POLICY "Character illustration owner update"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'character-illustrations'
  AND split_part(name, '/', 1) = (SELECT auth.uid())::text
  AND public.account_is_active()
  AND EXISTS (
    SELECT 1
    FROM public.characters c
    WHERE c.id::text = split_part(storage.objects.name, '/', 2)
      AND c.author_id = (SELECT auth.uid())
  )
)
WITH CHECK (
  bucket_id = 'character-illustrations'
  AND name ~* (
    '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
    '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
    '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\.(jpg|jpeg|png|webp)$'
  )
  AND split_part(name, '/', 1) = (SELECT auth.uid())::text
  AND public.account_is_active()
  AND EXISTS (
    SELECT 1
    FROM public.characters c
    WHERE c.id::text = split_part(storage.objects.name, '/', 2)
      AND c.author_id = (SELECT auth.uid())
  )
);

DROP POLICY IF EXISTS "Character illustration owner delete" ON storage.objects;
CREATE POLICY "Character illustration owner delete"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'character-illustrations'
  AND split_part(name, '/', 1) = (SELECT auth.uid())::text
  AND public.account_is_active()
  AND EXISTS (
    SELECT 1
    FROM public.characters c
    WHERE c.id::text = split_part(storage.objects.name, '/', 2)
      AND c.author_id = (SELECT auth.uid())
  )
);

DROP POLICY IF EXISTS "Character video owner delete" ON storage.objects;
CREATE POLICY "Character video owner delete"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'character-avatar-videos'
  AND split_part(name, '/', 1) = (SELECT auth.uid())::text
  AND public.account_is_active()
);
