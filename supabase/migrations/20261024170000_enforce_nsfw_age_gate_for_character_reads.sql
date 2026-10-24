-- Enforce NSFW age restrictions for every character SELECT path, including the owner.
-- Split the previous permissive FOR ALL owner policy so it cannot bypass SELECT age checks.
DROP POLICY IF EXISTS "characters_hide_soft_deleted_from_non_owner" ON public.characters;
DROP POLICY IF EXISTS "公開檢視公開且未下架的角色" ON public.characters;
DROP POLICY IF EXISTS "作者可管理自己的角色" ON public.characters;

CREATE POLICY "角色讀取須符合可見性與年齡限制"
ON public.characters
FOR SELECT
TO anon, authenticated
USING (
  (author_id = (SELECT auth.uid()) OR (visibility = 'public' AND deleted_at IS NULL))
  AND (
    is_nsfw IS NOT TRUE
    OR ((SELECT auth.uid()) IS NOT NULL AND private.current_user_is_adult())
  )
);

CREATE POLICY "作者可新增自己的角色"
ON public.characters
FOR INSERT
TO authenticated
WITH CHECK (
  author_id = (SELECT auth.uid())
  AND (is_nsfw IS NOT TRUE OR private.current_user_is_adult())
);

CREATE POLICY "作者可更新自己的角色"
ON public.characters
FOR UPDATE
TO authenticated
USING (
  author_id = (SELECT auth.uid())
  AND (is_nsfw IS NOT TRUE OR private.current_user_is_adult())
)
WITH CHECK (
  author_id = (SELECT auth.uid())
  AND (is_nsfw IS NOT TRUE OR private.current_user_is_adult())
);

CREATE POLICY "作者可刪除自己的角色"
ON public.characters
FOR DELETE
TO authenticated
USING (
  author_id = (SELECT auth.uid())
  AND (is_nsfw IS NOT TRUE OR private.current_user_is_adult())
);
