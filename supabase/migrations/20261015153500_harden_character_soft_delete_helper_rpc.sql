-- Keep the soft-delete guard inside the RLS policy instead of calling an exposed helper RPC.
ALTER POLICY "chat_sessions_no_new_deleted_character"
ON public.chat_sessions
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.characters AS c
    WHERE c.id = chat_sessions.character_id
      AND c.deleted_at IS NULL
  )
);

-- The helper is not an API security boundary; run it with caller privileges if retained.
ALTER FUNCTION public.character_is_not_soft_deleted(uuid) SECURITY INVOKER;
