-- Idempotent Encounter turn -> affinity/diary transaction.
CREATE TABLE IF NOT EXISTS public.encounter_turn_interaction_receipts (
  turn_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
  affinity integer,
  relationship_stage text,
  diary_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT encounter_turn_receipt_stage_check CHECK (
    relationship_stage IS NULL OR relationship_stage IN ('first_meeting','acquaintance','close','intimate','special')
  )
);
ALTER TABLE public.encounter_turn_interaction_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.encounter_turn_interaction_receipts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_turn_interaction_receipts TO service_role;

CREATE OR REPLACE FUNCTION public.record_encounter_turn_interaction(
  p_turn_id uuid,
  p_user_id uuid,
  p_character_id uuid,
  p_affinity_delta integer,
  p_event_type text,
  p_summary text,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_occurred_at timestamptz DEFAULT now()
)
RETURNS TABLE (affinity integer, relationship_stage text, diary_id uuid, idempotent boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_inserted integer;
  v_affinity integer;
  v_stage text;
  v_diary_id uuid;
  v_receipt public.encounter_turn_interaction_receipts%ROWTYPE;
  v_occurred_at timestamptz := COALESCE(p_occurred_at, now());
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Trusted backend required' USING ERRCODE = '42501';
  END IF;
  IF p_turn_id IS NULL OR p_user_id IS NULL OR p_character_id IS NULL THEN
    RAISE EXCEPTION 'Turn, user and character are required' USING ERRCODE = '22023';
  END IF;
  IF p_affinity_delta IS NULL OR p_affinity_delta < -10 OR p_affinity_delta > 10 THEN
    RAISE EXCEPTION 'Affinity delta must be between -10 and 10' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(char_length(btrim(p_event_type)), 0) NOT BETWEEN 1 AND 60
     OR COALESCE(char_length(btrim(p_summary)), 0) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'Invalid event type or diary summary' USING ERRCODE = '22023';
  END IF;
  IF p_metadata IS NULL OR jsonb_typeof(p_metadata) <> 'object' OR pg_column_size(p_metadata) > 4000 THEN
    RAISE EXCEPTION 'Invalid diary metadata' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'User not found' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.characters c WHERE c.id = p_character_id AND c.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Character not found or deleted' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.encounter_turn_interaction_receipts (turn_id, user_id, character_id)
  VALUES (p_turn_id, p_user_id, p_character_id)
  ON CONFLICT (turn_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT * INTO v_receipt
    FROM public.encounter_turn_interaction_receipts r
    WHERE r.turn_id = p_turn_id
    FOR UPDATE;
    IF v_receipt.user_id <> p_user_id OR v_receipt.character_id <> p_character_id THEN
      RAISE EXCEPTION 'Turn ID reused with different owner or character' USING ERRCODE = '23505';
    END IF;
    IF v_receipt.diary_id IS NULL OR v_receipt.affinity IS NULL OR v_receipt.relationship_stage IS NULL THEN
      RAISE EXCEPTION 'Interaction receipt incomplete' USING ERRCODE = '55000';
    END IF;
    RETURN QUERY SELECT v_receipt.affinity, v_receipt.relationship_stage, v_receipt.diary_id, true;
    RETURN;
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

  INSERT INTO public.encounter_diary (user_id, character_id, event_type, summary, occurred_at, metadata)
  VALUES (p_user_id, p_character_id, btrim(p_event_type), btrim(p_summary), v_occurred_at, p_metadata)
  RETURNING id INTO v_diary_id;

  UPDATE public.encounter_turn_interaction_receipts r
  SET affinity = v_affinity, relationship_stage = v_stage, diary_id = v_diary_id
  WHERE r.turn_id = p_turn_id;

  RETURN QUERY SELECT v_affinity, v_stage, v_diary_id, false;
END;
$$;

REVOKE ALL ON FUNCTION public.record_encounter_turn_interaction(uuid, uuid, uuid, integer, text, text, jsonb, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_encounter_turn_interaction(uuid, uuid, uuid, integer, text, text, jsonb, timestamptz)
  TO service_role;
COMMENT ON FUNCTION public.record_encounter_turn_interaction(uuid, uuid, uuid, integer, text, text, jsonb, timestamptz) IS
  'Atomically and idempotently updates Encounter affinity and private diary once per stable turn ID; service-role only.';
