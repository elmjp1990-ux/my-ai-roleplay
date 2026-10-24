-- Keep the creator's own NSFW character rows readable for management,
-- while retaining the adult-only gate for public discovery.
-- Underage users remain blocked from INSERT/UPDATE of NSFW rows by the
-- existing write policies; this migration does not weaken those checks.

DROP POLICY IF EXISTS "角色讀取須符合可見性與年齡限制" ON public.characters;
DROP POLICY IF EXISTS "characters_hide_soft_deleted_from_non_owner" ON public.characters;
DROP POLICY IF EXISTS "公開檢視公開且未下架的角色" ON public.characters;

CREATE POLICY "角色讀取須符合可見性與年齡限制"
ON public.characters
FOR SELECT
TO anon, authenticated
USING (
  author_id = (SELECT auth.uid())
  OR (
    visibility = 'public'
    AND deleted_at IS NULL
    AND (
      is_nsfw IS NOT TRUE
      OR ((SELECT auth.uid()) IS NOT NULL AND private.current_user_is_adult())
    )
  )
);
