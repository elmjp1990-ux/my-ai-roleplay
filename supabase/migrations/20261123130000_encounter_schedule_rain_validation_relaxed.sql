BEGIN;

-- Rain is character preference/context, not a schedule publication rule.
-- Remove the legacy consistency constraint and both publisher-side rain gates.
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_rain_fallback_consistency_check;

DO $publisher$
DECLARE
  v_definition text;
  v_hourly_block text;
  v_special_block text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  v_hourly_block := $hourly$
          IF (v_slot->>'is_outdoor')::boolean IS TRUE THEN
            IF COALESCE(v_slot->>'rain_fallback_location_key', '') NOT IN (
              'airport', 'commercial', 'night-bar', 'live-house', 'apartment', 'department-store', 'bookstore', 'cafe', 'university', 'hospital', 'luxury-apartment', 'convenience-store', 'private-club')
                 OR char_length(COALESCE(v_slot->>'rain_fallback_activity', '')) NOT BETWEEN 10 AND 30 THEN
              RAISE EXCEPTION 'schedule_hourly_option_rain_fallback_invalid' USING ERRCODE = '22023';
            END IF;
          ELSIF v_slot->>'rain_fallback_location_key' IS NOT NULL
             OR v_slot->>'rain_fallback_activity' IS NOT NULL THEN
            RAISE EXCEPTION 'schedule_hourly_option_unexpected_rain_fallback' USING ERRCODE = '22023';
          END IF;
$hourly$;

  v_special_block := $special$
        IF (v_special_slot->>'is_outdoor')::boolean IS TRUE THEN
          IF COALESCE(v_special_slot->>'rain_fallback_location_key', '') NOT IN (
            'airport', 'commercial', 'night-bar', 'live-house', 'apartment', 'department-store', 'bookstore', 'cafe', 'university', 'hospital', 'luxury-apartment', 'convenience-store', 'private-club')
             OR pg_catalog.char_length(COALESCE(v_special_slot->>'rain_fallback_activity', '')) NOT BETWEEN 1 AND 200
             OR pg_catalog.char_length(COALESCE(v_special_slot->>'rain_fallback_greeting', '')) NOT BETWEEN 150 AND 300 THEN
            RAISE EXCEPTION 'schedule_special_event_rain_fallback_invalid' USING ERRCODE = '22023';
          END IF;
        ELSIF v_special_slot->>'rain_fallback_location_key' IS NOT NULL
           OR v_special_slot->>'rain_fallback_activity' IS NOT NULL
           OR v_special_slot->>'rain_fallback_greeting' IS NOT NULL THEN
          RAISE EXCEPTION 'schedule_special_event_unexpected_rain_fallback' USING ERRCODE = '22023';
        END IF;
$special$;

  IF pg_catalog.strpos(v_definition, v_hourly_block) = 0 THEN
    RAISE EXCEPTION 'schedule_hourly_rain_validation_block_missing';
  END IF;
  IF pg_catalog.strpos(v_definition, v_special_block) = 0 THEN
    RAISE EXCEPTION 'schedule_special_event_rain_validation_block_missing';
  END IF;

  v_definition := pg_catalog.replace(v_definition, v_hourly_block, '');
  v_definition := pg_catalog.replace(v_definition, v_special_block, '');

  IF pg_catalog.strpos(v_definition, 'schedule_hourly_option_rain_fallback_invalid') > 0
     OR pg_catalog.strpos(v_definition, 'schedule_hourly_option_unexpected_rain_fallback') > 0
     OR pg_catalog.strpos(v_definition, 'schedule_special_event_rain_fallback_invalid') > 0
     OR pg_catalog.strpos(v_definition, 'schedule_special_event_unexpected_rain_fallback') > 0 THEN
    RAISE EXCEPTION 'schedule_rain_validation_removal_incomplete';
  END IF;

  EXECUTE v_definition;
END;
$publisher$;

COMMIT;
