-- Read the canonical per-turn affinity state so the city card reflects recent Encounter turns,
-- even when the session has not reached schedule settlement yet.
CREATE OR REPLACE FUNCTION public.get_encounter_character_affinity(p_character_id uuid)
RETURNS TABLE(affinity integer, relationship_stage text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF p_character_id IS NULL THEN
    RAISE EXCEPTION 'Character ID is required' USING ERRCODE='22023';
  END IF;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';
  END IF;

  RETURN QUERY
  SELECT state.affinity, state.relationship_stage
  FROM public.encounter_character_state AS state
  WHERE state.user_id=v_user_id
    AND state.character_id=p_character_id
  LIMIT 1;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_encounter_character_affinity(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_encounter_character_affinity(uuid) TO authenticated;
