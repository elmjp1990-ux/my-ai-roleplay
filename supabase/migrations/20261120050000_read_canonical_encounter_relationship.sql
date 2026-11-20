-- Owner-scoped relationship display reads the canonical live state, including
-- per-turn Encounter updates before the current session has been settled.
CREATE OR REPLACE FUNCTION public.get_encounter_character_relationship(p_character_id uuid)
RETURNS TABLE(affinity integer,relationship_stage text,updated_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid:=auth.uid();
BEGIN
  IF p_character_id IS NULL THEN
    RAISE EXCEPTION 'Character ID is required' USING ERRCODE='22023';
  END IF;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
  SELECT state.affinity,state.relationship_stage,state.updated_at
  FROM public.encounter_character_state AS state
  WHERE state.user_id=v_user_id AND state.character_id=p_character_id;
  IF FOUND THEN RETURN; END IF;
  RETURN QUERY
  SELECT story.affinity,story.relationship_stage,story.updated_at
  FROM public.story_relationship_states AS story
  JOIN public.chat_sessions AS session ON session.id=story.session_id
  WHERE story.user_id=v_user_id AND story.character_id=p_character_id
    AND session.user_id=v_user_id AND session.chat_mode='story'
    AND session.deleted_at IS NULL
  ORDER BY story.updated_at DESC,story.session_id DESC
  LIMIT 1;
END;
$$;
REVOKE ALL ON FUNCTION public.get_encounter_character_relationship(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_encounter_character_relationship(uuid) TO authenticated,service_role;
COMMENT ON FUNCTION public.get_encounter_character_relationship(uuid) IS
  'Returns the authenticated owner’s canonical Encounter relationship state (or latest Story relationship fallback) for city-card display.';
