-- Allow a Story owner to read only their own relationship display state.
CREATE OR REPLACE FUNCTION public.get_story_relationship_state(p_session_id uuid)
RETURNS TABLE(
  affinity integer,
  relationship_stage text,
  origin_mode text,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'Story session ID is required' USING ERRCODE='22023';
  END IF;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';
  END IF;

  RETURN QUERY
  SELECT state.affinity,state.relationship_stage,state.origin_mode,state.updated_at
  FROM public.story_relationship_states AS state
  JOIN public.chat_sessions AS session
    ON session.id=state.session_id
  WHERE state.session_id=p_session_id
    AND state.user_id=v_user_id
    AND session.user_id=v_user_id
    AND session.chat_mode='story'
    AND session.deleted_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.get_story_relationship_state(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_story_relationship_state(uuid) TO authenticated,service_role;

COMMENT ON FUNCTION public.get_story_relationship_state(uuid) IS
  'Returns only the authenticated owner’s current Story affinity and relationship stage for UI display; internal relationship tables remain private.';
