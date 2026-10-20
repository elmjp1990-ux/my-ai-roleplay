-- Keep auth.uid() evaluated once per statement in RLS predicates.
-- This preserves the existing ownership checks while avoiding per-row auth function calls.

ALTER POLICY "使用者僅能修改自己的檔案" ON public.profiles
USING ((SELECT auth.uid()) = id)
WITH CHECK ((SELECT auth.uid()) = id);

ALTER POLICY "作者可管理自己的角色" ON public.characters
USING ((SELECT auth.uid()) = author_id)
WITH CHECK ((SELECT auth.uid()) = author_id);

ALTER POLICY "作者可管理故事" ON public.character_stories
USING ((SELECT auth.uid()) IN (SELECT c.author_id FROM public.characters c WHERE c.id = character_stories.character_id))
WITH CHECK ((SELECT auth.uid()) IN (SELECT c.author_id FROM public.characters c WHERE c.id = character_stories.character_id));

ALTER POLICY "玩家僅能存取自己的聊天" ON public.conversations
USING ((SELECT auth.uid()) = user_id)
WITH CHECK ((SELECT auth.uid()) = user_id);

ALTER POLICY "玩家僅能存取自己聊天的訊息" ON public.messages
USING ((SELECT auth.uid()) IN (SELECT c.user_id FROM public.conversations c WHERE c.id = messages.conversation_id))
WITH CHECK ((SELECT auth.uid()) IN (SELECT c.user_id FROM public.conversations c WHERE c.id = messages.conversation_id));

ALTER POLICY "玩家僅能檢視自己的錢包" ON public.wallet_accounts
USING ((SELECT auth.uid()) = user_id);

ALTER POLICY "玩家僅能檢視自己的帳本" ON public.wallet_transactions
USING ((SELECT auth.uid()) = user_id);
