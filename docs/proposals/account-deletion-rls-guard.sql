-- PROPOSAL ONLY — NOT APPLIED TO SUPABASE.
-- Purpose: ensure an account with any account_deletion_requests row cannot
-- use permissive owner policies to bypass the separate account_must_be_active policy.
-- Review policy names and intended owner behavior against the live database before execution.
-- Run only in a controlled test project first; this file is not a migration.

BEGIN;

DROP POLICY IF EXISTS "作者可管理自己的角色" ON public.characters;
CREATE POLICY "作者可管理自己的角色"
ON public.characters
AS PERMISSIVE
FOR ALL
TO public
USING (
  auth.uid() = author_id
  AND public.account_is_active()
)
WITH CHECK (
  auth.uid() = author_id
  AND public.account_is_active()
);

DROP POLICY IF EXISTS "作者可管理故事" ON public.character_stories;
CREATE POLICY "作者可管理故事"
ON public.character_stories
AS PERMISSIVE
FOR ALL
TO public
USING (
  auth.uid() IN (
    SELECT c.author_id
    FROM public.characters AS c
    WHERE c.id = character_stories.character_id
  )
  AND public.account_is_active()
)
WITH CHECK (
  auth.uid() IN (
    SELECT c.author_id
    FROM public.characters AS c
    WHERE c.id = character_stories.character_id
  )
  AND public.account_is_active()
);

DROP POLICY IF EXISTS "玩家僅能存取自己的聊天" ON public.conversations;
CREATE POLICY "玩家僅能存取自己的聊天"
ON public.conversations
AS PERMISSIVE
FOR ALL
TO public
USING (
  auth.uid() = user_id
  AND public.account_is_active()
)
WITH CHECK (
  auth.uid() = user_id
  AND public.account_is_active()
);

COMMIT;

-- READ-ONLY VERIFICATION AFTER A CONTROLLED TEST:
-- SELECT schemaname, tablename, policyname, roles, cmd, qual, with_check
-- FROM pg_policies
-- WHERE schemaname = 'public'
--   AND tablename IN ('characters', 'character_stories', 'conversations')
-- ORDER BY tablename, policyname;
--
-- Test with a disposable account:
-- 1. Confirm normal owner CRUD works when no deletion request exists.
-- 2. Insert a deletion request only in a disposable test environment.
-- 3. Confirm owner writes to these tables are denied while the request exists.
-- 4. Confirm public approved-character/story reads remain available according to their
--    separate SELECT policies.
-- 5. Cancel the request before the test deadline and confirm owner CRUD is restored.
-- Never use a real user's account or delete any user data for this policy test.
