-- Bind every Story summary/evaluation batch to settled turns from the same Story session.
-- source_turn_ids are chat_turn_charges.turn_id values, never client-supplied foreign-session IDs.
CREATE OR REPLACE FUNCTION public.validate_story_relationship_batch_sources()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_expected_count integer;
  v_distinct_count integer;
  v_valid_count integer;
BEGIN
  v_expected_count := NEW.last_turn_number - NEW.first_turn_number + 1;

  IF NEW.first_turn_number < 1
     OR NEW.last_turn_number < NEW.first_turn_number
     OR v_expected_count NOT BETWEEN 1 AND 5
     OR cardinality(NEW.source_turn_ids) <> v_expected_count THEN
    RAISE EXCEPTION 'Story batch turn range does not match source turn count' USING ERRCODE='23514';
  END IF;

  SELECT count(DISTINCT source_id)
  INTO v_distinct_count
  FROM unnest(NEW.source_turn_ids) AS source(source_id);

  IF v_distinct_count <> cardinality(NEW.source_turn_ids) THEN
    RAISE EXCEPTION 'Story batch source turn IDs must be unique' USING ERRCODE='23514';
  END IF;

  SELECT count(*)
  INTO v_valid_count
  FROM unnest(NEW.source_turn_ids) AS source(source_id)
  JOIN public.chat_turn_charges AS charge
    ON charge.turn_id=source.source_id
  WHERE charge.session_id=NEW.session_id
    AND charge.user_id=NEW.user_id
    AND charge.status='settled';

  IF v_valid_count <> cardinality(NEW.source_turn_ids) THEN
    RAISE EXCEPTION 'Story batch sources must be settled turns from the same session and owner' USING ERRCODE='23514';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_story_relationship_batch_sources() FROM PUBLIC,anon,authenticated;

DROP TRIGGER IF EXISTS validate_story_relationship_batch_sources ON public.story_relationship_batches;
CREATE TRIGGER validate_story_relationship_batch_sources
  BEFORE INSERT OR UPDATE OF session_id,user_id,source_turn_ids,first_turn_number,last_turn_number
  ON public.story_relationship_batches
  FOR EACH ROW EXECUTE FUNCTION public.validate_story_relationship_batch_sources();

COMMENT ON FUNCTION public.validate_story_relationship_batch_sources() IS
  'Ensures a Story summary/evaluation batch references only unique, settled chat turns belonging to its own Story session and owner.';
