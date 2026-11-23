-- Keep zero-turn Encounter cancellation compatible with the NOT NULL settlement_result column.
-- A cancelled no-interaction scene has no affinity settlement, but it still stores
-- a small explicit cancellation result instead of writing SQL NULL.
DO $migration$
DECLARE
  v_signature regprocedure;
  v_definition text;
  v_old text := 'settlement_result=NULL';
  v_new text := 'settlement_result=jsonb_build_object(''no_interaction'',true,''turn_count'',0)';
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'public.set_encounter_session_lifecycle_state(uuid,uuid,text)'::regprocedure,
    'public.settle_encounter_session(uuid,integer,text,jsonb,jsonb)'::regprocedure
  ] LOOP
    v_definition := pg_catalog.pg_get_functiondef(v_signature);
    IF pg_catalog.strpos(v_definition, v_old) = 0 THEN
      RAISE EXCEPTION 'encounter_zero_turn_settlement_result_anchor_missing: %', v_signature;
    END IF;
    v_definition := pg_catalog.replace(v_definition, v_old, v_new);
    EXECUTE v_definition;
  END LOOP;
END;
$migration$;
