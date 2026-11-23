BEGIN;

-- Rain is character preference/context, not a schedule publication rule.
-- Remove the legacy rain fallback constraint without changing generation output.
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_rain_fallback_consistency_check;

DO $publisher$
DECLARE
  v_definition text;
  v_start integer;
  v_raise integer;
  v_end_marker integer;
  v_end integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  -- Remove the complete publisher-side rain fallback validation block. Keep
  -- activity/location/weight/24-hour coverage checks intact.
  v_start := pg_catalog.strpos(
    v_definition,
    'IF (v_slot->>''is_outdoor'')::boolean IS TRUE'
  );
  IF v_start = 0 THEN
    RAISE EXCEPTION 'schedule_rain_validation_block_start_missing';
  END IF;

  v_raise := pg_catalog.strpos(
    pg_catalog.substr(v_definition, v_start),
    'schedule_hourly_option_rain_fallback_invalid'
  );
  IF v_raise = 0 THEN
    RAISE EXCEPTION 'schedule_rain_validation_block_error_marker_missing';
  END IF;

  v_end_marker := v_start + v_raise - 1;
  v_end := v_end_marker
    + pg_catalog.strpos(pg_catalog.substr(v_definition, v_end_marker), 'END IF;')
    + pg_catalog.length('END IF;') - 2;
  IF v_end < v_start OR v_end > pg_catalog.length(v_definition) THEN
    RAISE EXCEPTION 'schedule_rain_validation_block_end_invalid';
  END IF;

  v_definition := pg_catalog.substr(v_definition, 1, v_start - 1)
    || pg_catalog.substr(v_definition, v_end + 1);
  EXECUTE v_definition;
END;
$publisher$;

COMMIT;
