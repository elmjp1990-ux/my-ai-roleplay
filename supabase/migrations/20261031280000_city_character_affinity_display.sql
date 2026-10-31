-- Return only the authenticated user's latest settled Encounter affinity for one character.
CREATE OR REPLACE FUNCTION public.get_latest_settled_encounter_affinity(p_character_id uuid)
RETURNS TABLE(
  session_id uuid,
  settled_at timestamptz,
  affinity integer,
  relationship_stage text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
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
  SELECT lifecycle.session_id,
         lifecycle.settled_at,
         (lifecycle.settlement_result->>'final_affinity')::integer,
         lifecycle.settlement_result->>'relationship_stage'
  FROM public.encounter_session_lifecycle AS lifecycle
  WHERE lifecycle.user_id=v_user_id
    AND lifecycle.character_id=p_character_id
    AND lifecycle.status='settled'
    AND lifecycle.settled_at IS NOT NULL
    AND jsonb_typeof(lifecycle.settlement_result)='object'
    AND (lifecycle.settlement_result->>'final_affinity') ~ '^-?[0-9]{1,3}$'
    AND (lifecycle.settlement_result->>'final_affinity')::integer BETWEEN -100 AND 100
    AND lifecycle.settlement_result->>'relationship_stage' IN (
      'hostile','dislike','wary','first_meeting',
      'acquaintance','close','intimate','special'
    )
  ORDER BY lifecycle.settled_at DESC,lifecycle.session_id
  LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.get_latest_settled_encounter_affinity(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_latest_settled_encounter_affinity(uuid) TO authenticated,service_role;

COMMENT ON FUNCTION public.get_latest_settled_encounter_affinity(uuid) IS
  'Returns only the authenticated caller’s latest valid settled Encounter affinity and relationship stage for a character.';
