BEGIN;

-- Encounter schedules now store only windows in which a player can actually
-- meet the character. Gaps are intentional: no matching row means no map pin.
-- Keep the database publisher as the final authority for scene keys and timing.
DO $migration$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  IF v_definition IS NULL THEN
    RAISE EXCEPTION 'publish_encounter_schedule_batch_definition_missing';
  END IF;

  v_old := $old$OR jsonb_array_length(v_variant->'slots') NOT BETWEEN 2 AND 4$old$;
  IF pg_catalog.strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'daily_slot_count_contract_not_found';
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old,
    $new$OR jsonb_array_length(v_variant->'slots') NOT BETWEEN 0 AND 4$new$);

  v_old := $old$IF jsonb_array_length(v_special_event->'slots') NOT BETWEEN 2 AND 4 THEN$new$;
  IF pg_catalog.strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'special_event_slot_count_contract_not_found';
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old,
    $new$IF jsonb_array_length(v_special_event->'slots') NOT BETWEEN 1 AND 4 THEN$new$);

  v_old := $old$          -- Every daily variant must cover 00:00 through the next 00:00
          -- without gaps. A final 22:00-00:00 slot is represented as a wrap to midnight.
          IF EXISTS (
            WITH intervals AS (
              SELECT
                (EXTRACT(HOUR FROM (slot->>'start_time')::time)::integer * 60) AS start_minute,
                (EXTRACT(HOUR FROM (slot->>'end_time')::time)::integer * 60)
                  + CASE
                      WHEN (slot->>'end_time')::time <= (slot->>'start_time')::time THEN 1440
                      ELSE 0
                    END AS end_minute
              FROM jsonb_array_elements(v_variant->'slots') AS slots(slot)
            ),
            ordered AS (
              SELECT start_minute, end_minute,
                pg_catalog.lag(end_minute) OVER (ORDER BY start_minute) AS previous_end
              FROM intervals
            ),
            coverage AS (
              SELECT
                pg_catalog.count(*) AS slot_count,
                pg_catalog.min(start_minute) AS first_start,
                pg_catalog.max(end_minute) AS final_end,
                pg_catalog.bool_or(previous_end IS NOT NULL AND previous_end <> start_minute) AS has_gap
              FROM ordered
            )
            SELECT 1 FROM coverage
            WHERE slot_count < 2 OR first_start <> 0 OR final_end <> 1440 OR COALESCE(has_gap, true)
          ) THEN
            RAISE EXCEPTION 'schedule_variant_24_hour_coverage_incomplete' USING ERRCODE = '22023';
          END IF;

$old$;
  IF pg_catalog.strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'daily_coverage_contract_not_found';
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, '');

  v_old := $old$      IF EXISTS (
        WITH intervals AS (
          SELECT
            EXTRACT(HOUR FROM (slot->>'start_time')::time)::integer * 60 AS start_minute,
            EXTRACT(HOUR FROM (slot->>'end_time')::time)::integer * 60
              + CASE WHEN (slot->>'end_time')::time <= (slot->>'start_time')::time THEN 1440 ELSE 0 END AS end_minute
          FROM jsonb_array_elements(v_special_event->'slots') AS slots(slot)
        ),
        ordered AS (
          SELECT start_minute, end_minute,
            pg_catalog.lag(end_minute) OVER (ORDER BY start_minute) AS previous_end
          FROM intervals
        ),
        coverage AS (
          SELECT pg_catalog.count(*) AS slot_count,
            pg_catalog.min(start_minute) AS first_start,
            pg_catalog.max(end_minute) AS final_end,
            pg_catalog.bool_or(previous_end IS NOT NULL AND previous_end <> start_minute) AS has_gap
          FROM ordered
        )
        SELECT 1 FROM coverage
        WHERE slot_count < 2 OR first_start <> 0 OR final_end <> 1440 OR COALESCE(has_gap, true)
      ) THEN
        RAISE EXCEPTION 'schedule_special_event_24_hour_coverage_incomplete' USING ERRCODE = '22023';
      END IF;

$old$;
  IF pg_catalog.strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'special_event_coverage_contract_not_found';
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, '');

  -- The publisher accepts all canonical keys, but the Edge Function only
  -- passes keys present in get_encounter_scene_catalog().
  v_old := $old$'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
               'department-store', 'bookstore', 'cafe', 'park', 'shopping-street'$old$;
  v_new := $new$'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
               'department-store', 'bookstore', 'cafe', 'park', 'shopping-street',
               'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema',
               'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery',
               'community-center', 'music-studio', 'bakery', 'coworking-space'$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'canonical_scene_key_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$migration$;

COMMIT;
