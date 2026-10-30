-- Trusted Encounter interaction persistence.
-- This RPC is intentionally service-role-only. It must be called by a trusted backend
-- after validating and processing an actual Encounter turn; never call it from the browser.
CREATE OR REPLACE FUNCTION public.record_encounter_interaction(
  p_user_id uuid,
  p_character_id uuid,
  p_affinity_delta integer,
  p_event_type text,
  p_summary text,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_occurred_at timestamptz DEFAULT now()
)
RETURNS TABLE (
  affinity integer,
  relationship_stage text,
  diary_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_affinity integer;
  v_stage text;
  v_diary_id uuid;
  v_occurred_at timestamptz := COALESCE(p_occurred_at, now());
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Trusted backend required' USING ERRCODE = '42501';
  END IF;

  IF p_user_id IS NULL OR p_character_id IS NULL THEN
    RAISE EXCEPTION 'User and character are required' USING ERRCODE = '22023';
  END IF;
  IF p_affinity_delta IS NULL OR p_affinity_delta < -10 OR p_affinity_delta > 10 THEN
    RAISE EXCEPTION 'Affinity delta must be between -10 and 10' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(char_length(btrim(p_event_type)), 0) NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'Invalid event type' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(char_length(btrim(p_summary)), 0) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'Invalid diary summary' USING ERRCODE = '22023';
  END IF;
  IF p_metadata IS NULL OR jsonb_typeof(p_metadata) <> 'object'
     OR pg_column_size(p_metadata) > 4000 THEN
    RAISE EXCEPTION 'Invalid diary metadata' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'User not found' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.characters c
    WHERE c.id = p_character_id AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Character not found or deleted' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.encounter_character_state AS current_state (
    user_id, character_id, affinity, relationship_stage,
    first_met_at, last_interaction_at, updated_at
  )
  VALUES (
    p_user_id, p_character_id, GREATEST(0, LEAST(100, p_affinity_delta)),
    'first_meeting', v_occurred_at, v_occurred_at, now()
  )
  ON CONFLICT (user_id, character_id) DO UPDATE
  SET affinity = GREATEST(0, LEAST(100, current_state.affinity + p_affinity_delta)),
      last_interaction_at = GREATEST(current_state.last_interaction_at, EXCLUDED.last_interaction_at),
      updated_at = now()
  RETURNING current_state.affinity INTO v_affinity;

  v_stage := CASE
    WHEN v_affinity >= 80 THEN 'special'
    WHEN v_affinity >= 50 THEN 'intimate'
    WHEN v_affinity >= 20 THEN 'close'
    WHEN v_affinity >= 1 THEN 'acquaintance'
    ELSE 'first_meeting'
  END;

  UPDATE public.encounter_character_state s
  SET relationship_stage = v_stage,
      first_met_at = COALESCE(s.first_met_at, v_occurred_at),
      updated_at = now()
  WHERE s.user_id = p_user_id AND s.character_id = p_character_id;

  INSERT INTO public.encounter_diary (
    user_id, character_id, event_type, summary, occurred_at, metadata
  )
  VALUES (
    p_user_id, p_character_id, btrim(p_event_type), btrim(p_summary), v_occurred_at, p_metadata
  )
  RETURNING id INTO v_diary_id;

  RETURN QUERY SELECT v_affinity, v_stage, v_diary_id;
END;
$$;

REVOKE ALL ON FUNCTION public.record_encounter_interaction(uuid, uuid, integer, text, text, jsonb, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_encounter_interaction(uuid, uuid, integer, text, text, jsonb, timestamptz)
  TO service_role;

COMMENT ON FUNCTION public.record_encounter_interaction(uuid, uuid, integer, text, text, jsonb, timestamptz) IS
  'Atomically updates per-user Encounter affinity and inserts a private diary event. Callable only by trusted service-role backend after validating a real interaction.';
