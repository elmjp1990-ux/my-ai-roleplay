-- Enforce character eligibility for new chat sessions at the database boundary.
-- Existing sessions are unaffected; this policy applies only to INSERT.
CREATE OR REPLACE FUNCTION public.character_can_start_chat(p_character_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.characters c
    WHERE c.id = p_character_id
      AND c.deleted_at IS NULL
      AND (
        c.author_id = (SELECT auth.uid())
        OR (c.visibility = 'public' AND c.review_status = 'approved')
      )
  );
$$;

REVOKE ALL ON FUNCTION public.character_can_start_chat(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.character_can_start_chat(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.character_can_start_chat(uuid) TO authenticated;

-- Restrictive policies are ANDed with existing INSERT policies, so a permissive
-- legacy policy cannot let a user start a new chat with another user's private
-- or soft-deleted character. Existing chat_sessions rows remain readable under
-- their existing policies.
DROP POLICY IF EXISTS chat_sessions_character_must_be_accessible_for_new_chat
  ON public.chat_sessions;
CREATE POLICY chat_sessions_character_must_be_accessible_for_new_chat
ON public.chat_sessions
AS RESTRICTIVE
FOR INSERT
TO authenticated
WITH CHECK (public.character_can_start_chat(character_id));
