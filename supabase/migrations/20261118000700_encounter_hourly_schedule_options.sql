BEGIN;

-- Daily AI schedules now store one row per weighted option inside each hour.
-- Legacy primary/alternative rows remain readable until the character's next
-- normal schedule regeneration; no mass AI regeneration is triggered here.
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_variant_key_check,
  DROP CONSTRAINT IF EXISTS character_schedules_special_event_check,
  DROP CONSTRAINT IF EXISTS character_schedules_option_weight_check;

ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_variant_key_check
    CHECK (variant_key IN ('primary', 'alternative', 'special', 'option_1', 'option_2', 'option_3')),
  ADD CONSTRAINT character_schedules_special_event_check
    CHECK (
      (variant_key = 'special'
        AND special_event_key IN ('taiwan_public_holiday', 'lunar_new_year', 'valentines_day', 'christmas')
        AND day_type = 'any'
        AND variant_weight = 100)
      OR (variant_key IN ('primary', 'alternative') AND special_event_key IS NULL)
      OR (variant_key IN ('option_1', 'option_2', 'option_3')
        AND source_type = 'ai'
        AND special_event_key IS NULL
        AND day_type IN ('weekday', 'holiday'))
    ),
  ADD CONSTRAINT character_schedules_option_weight_check
    CHECK (variant_key NOT IN ('option_1', 'option_2', 'option_3') OR variant_weight BETWEEN 1 AND 100);

CREATE UNIQUE INDEX IF NOT EXISTS character_schedules_ai_hourly_option_unique_idx
  ON public.character_schedules (
    character_id, day_type, start_time, end_time, variant_key
  )
  WHERE source_type = 'ai'
    AND is_active IS TRUE
    AND special_event_key IS NULL
    AND variant_key IN ('option_1', 'option_2', 'option_3');

COMMENT ON COLUMN public.character_schedules.variant_weight IS
  'For AI hourly rows, this is the independent probability weight of this option within the same character/day type/time block; each block must total 100. Legacy primary/alternative rows retain their original day-level meaning until regenerated.';

-- Replace only the daily publish loop, preserving the existing batch lease,
-- private-context, scene-description, natural-location, and special-event logic.
DO $publisher$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_start integer;
  v_end integer;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  v_old := '  v_output_count integer := 0;';
  v_new := v_old || E'\n  v_option_index integer := 0;\n  v_option_weight integer := 0;\n  v_option_weight_total integer := 0;\n  v_block_start time;\n  v_block_end time;\n  v_previous_block_start time;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'hourly_publisher_variable_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $marker$    FOREACH v_day_type IN ARRAY ARRAY['weekday', 'holiday']::text[]
    LOOP$marker$;
  v_start := pg_catalog.strpos(v_definition, v_old);
  v_new := $marker$    IF jsonb_typeof(v_item->'special_events') IS DISTINCT FROM 'array' THEN$marker$;
  v_end := pg_catalog.strpos(pg_catalog.substr(v_definition, v_start), v_new) + v_start - 1;
  IF v_start = 0 OR v_end < v_start THEN
    RAISE EXCEPTION 'hourly_publisher_daily_loop_boundaries_missing';
  END IF;

  v_new := $hourly_loop$    FOREACH v_day_type IN ARRAY ARRAY['weekday', 'holiday']::text[]
    LOOP
      IF jsonb_typeof(v_item->'variants'->v_day_type) IS DISTINCT FROM 'array'
         OR jsonb_array_length(v_item->'variants'->v_day_type) > 24 THEN
        RAISE EXCEPTION 'schedule_hourly_blocks_invalid' USING ERRCODE = '22023';
      END IF;

      v_previous_block_start := NULL;
      FOR v_variant IN SELECT value FROM jsonb_array_elements(v_item->'variants'->v_day_type)
      LOOP
        IF jsonb_typeof(v_variant) IS DISTINCT FROM 'object'
           OR jsonb_object_length(v_variant) <> 3
           OR COALESCE(v_variant->>'start_time', '') !~ '^([01][0-9]|2[0-3]):00$'
           OR COALESCE(v_variant->>'end_time', '') !~ '^([01][0-9]|2[0-3]):00$' THEN
          RAISE EXCEPTION 'schedule_hourly_block_shape_invalid' USING ERRCODE = '22023';
        END IF;

        v_block_start := (v_variant->>'start_time')::time;
        v_block_end := (v_variant->>'end_time')::time;
        IF v_block_end <> (v_block_start + interval '1 hour')::time THEN
          RAISE EXCEPTION 'schedule_hourly_block_must_be_exactly_one_hour' USING ERRCODE = '22023';
        END IF;
        IF v_previous_block_start IS NOT NULL AND v_block_start <= v_previous_block_start THEN
          RAISE EXCEPTION 'schedule_hourly_blocks_must_be_sorted_and_unique' USING ERRCODE = '22023';
        END IF;
        v_previous_block_start := v_block_start;

        IF jsonb_typeof(v_variant->'options') IS DISTINCT FROM 'array'
           OR jsonb_array_length(v_variant->'options') NOT BETWEEN 1 AND 3 THEN
          RAISE EXCEPTION 'schedule_hourly_options_count_invalid' USING ERRCODE = '22023';
        END IF;

        v_option_index := 0;
        v_option_weight_total := 0;
        FOR v_slot IN SELECT value FROM jsonb_array_elements(v_variant->'options')
        LOOP
          v_option_index := v_option_index + 1;
          IF jsonb_typeof(v_slot) IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'schedule_hourly_option_object_invalid' USING ERRCODE = '22023';
          END IF;
          IF jsonb_object_length(v_slot) <> 11
             OR v_slot->>'option_key' <> ('option_' || v_option_index::text)
             OR COALESCE(v_slot->>'weight', '') !~ '^[0-9]{1,3}$' THEN
            RAISE EXCEPTION 'schedule_hourly_option_contract_invalid' USING ERRCODE = '22023';
          END IF;

          v_option_weight := (v_slot->>'weight')::integer;
          IF v_option_weight NOT BETWEEN 1 AND 100
             OR (
               NULLIF(v_slot->>'location_key', '') IS NOT NULL
               AND NULLIF(v_slot->>'location_key', '') NOT IN (
                 'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
                 'department-store', 'bookstore', 'cafe', 'park', 'shopping-street',
                 'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema',
                 'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery',
                 'community-center', 'music-studio', 'bakery', 'coworking-space'
               )
             )
             OR char_length(COALESCE(v_slot->>'location_description', '')) NOT BETWEEN 1 AND 120
             OR char_length(COALESCE(v_slot->>'scene_description', '')) NOT BETWEEN 8 AND 500
             OR char_length(COALESCE(v_slot->>'activity', '')) NOT BETWEEN 1 AND 200
             OR char_length(COALESCE(v_slot->>'encounter_greeting', '')) NOT BETWEEN 150 AND 300
             OR jsonb_typeof(v_slot->'is_outdoor') IS DISTINCT FROM 'boolean' THEN
            RAISE EXCEPTION 'schedule_hourly_option_invalid' USING ERRCODE = '22023';
          END IF;

          IF (v_slot->>'is_outdoor')::boolean IS TRUE THEN
            IF COALESCE(v_slot->>'rain_fallback_location_key', '') NOT IN (
              'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
              'department-store', 'bookstore', 'cafe'
            )
               OR char_length(COALESCE(v_slot->>'rain_fallback_activity', '')) NOT BETWEEN 1 AND 200
               OR char_length(COALESCE(v_slot->>'rain_fallback_greeting', '')) NOT BETWEEN 150 AND 300 THEN
              RAISE EXCEPTION 'schedule_hourly_option_rain_fallback_invalid' USING ERRCODE = '22023';
            END IF;
          ELSIF v_slot->>'rain_fallback_location_key' IS NOT NULL
             OR v_slot->>'rain_fallback_activity' IS NOT NULL
             OR v_slot->>'rain_fallback_greeting' IS NOT NULL THEN
            RAISE EXCEPTION 'schedule_hourly_option_unexpected_rain_fallback' USING ERRCODE = '22023';
          END IF;

          v_option_weight_total := v_option_weight_total + v_option_weight;
          INSERT INTO public.character_schedules (
            character_id, weekday, day_type, start_time, end_time,
            location_key, location_description, activity, scene_description,
            priority, is_active, source_type, variant_key, variant_weight,
            encounter_greeting, is_outdoor, rain_fallback_location_key,
            rain_fallback_activity, rain_fallback_greeting, batch_id, source_hash
          ) VALUES (
            v_character_id, NULL, v_day_type, v_block_start, v_block_end,
            NULLIF(v_slot->>'location_key', ''), v_slot->>'location_description',
            v_slot->>'activity', v_slot->>'scene_description',
            50, true, 'ai', v_slot->>'option_key', v_option_weight,
            v_slot->>'encounter_greeting', (v_slot->>'is_outdoor')::boolean,
            NULLIF(v_slot->>'rain_fallback_location_key', ''),
            NULLIF(v_slot->>'rain_fallback_activity', ''),
            NULLIF(v_slot->>'rain_fallback_greeting', ''),
            p_batch_id, v_job.source_hash
          );
        END LOOP;

        IF v_option_weight_total <> 100 THEN
          RAISE EXCEPTION 'schedule_hourly_option_weights_must_sum_100' USING ERRCODE = '22023';
        END IF;
      END LOOP;
    END LOOP;

$hourly_loop$;

  v_definition := pg_catalog.substr(v_definition, 1, v_start - 1)
    || v_new
    || pg_catalog.substr(v_definition, v_end);

  EXECUTE v_definition;
END;
$publisher$;

-- Select one option independently for each character/date/hour. The hash seed
-- is stable for the same day and hour, so map refreshes cannot reroll a character.
-- Legacy day-level primary/alternative rows remain supported until regenerated.
DO $resolver$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.resolve_encounter_character_schedule(uuid,uuid,text,timestamptz)'::regprocedure
  ) INTO v_definition;

  v_old := '  v_variant_key text;';
  v_new := v_old || E'\n  v_option_roll integer;\n  v_selected_schedule_id uuid;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'hourly_resolver_variable_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$      SELECT s.variant_weight INTO v_primary_weight
      FROM public.character_schedules s
      WHERE s.character_id = p_character_id
        AND s.source_type = 'ai'
        AND s.is_active IS TRUE
        AND s.day_type = v_day_type
        AND s.variant_key = 'primary'
        AND s.special_event_key IS NULL
      ORDER BY s.priority DESC, s.start_time
      LIMIT 1;
      v_primary_weight := COALESCE(v_primary_weight, CASE WHEN v_day_type = 'weekday' THEN 80 ELSE 60 END);
      v_variant_roll := pg_catalog.mod(
        pg_catalog.abs(pg_catalog.hashtext(p_character_id::text || v_schedule_date::text || v_day_type)::bigint),
        100
      )::integer;
      v_variant_key := CASE WHEN v_variant_roll < v_primary_weight THEN 'primary' ELSE 'alternative' END;
      IF v_row.variant_key <> v_variant_key THEN CONTINUE; END IF;$old$;
  v_new := $new$      IF v_row.variant_key IN ('primary', 'alternative') THEN
        SELECT s.variant_weight INTO v_primary_weight
        FROM public.character_schedules s
        WHERE s.character_id = p_character_id
          AND s.source_type = 'ai'
          AND s.is_active IS TRUE
          AND s.day_type = v_day_type
          AND s.variant_key = 'primary'
          AND s.special_event_key IS NULL
        ORDER BY s.priority DESC, s.start_time
        LIMIT 1;
        v_primary_weight := COALESCE(v_primary_weight, CASE WHEN v_day_type = 'weekday' THEN 80 ELSE 60 END);
        v_variant_roll := pg_catalog.mod(
          pg_catalog.abs(pg_catalog.hashtext(p_character_id::text || v_schedule_date::text || v_day_type)::bigint),
          100
        )::integer;
        v_variant_key := CASE WHEN v_variant_roll < v_primary_weight THEN 'primary' ELSE 'alternative' END;
        IF v_row.variant_key <> v_variant_key THEN CONTINUE; END IF;
      ELSE
        v_option_roll := pg_catalog.mod(
          pg_catalog.abs(pg_catalog.hashtext(
            p_character_id::text || v_schedule_date::text || v_row.start_time::text || 'hourly-options-v1'
          )::bigint),
          100
        )::integer;
        SELECT weighted.id INTO v_selected_schedule_id
        FROM (
          SELECT option_row.id,
            pg_catalog.sum(option_row.variant_weight) OVER (
              ORDER BY option_row.variant_key
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS cumulative_weight
          FROM public.character_schedules option_row
          WHERE option_row.character_id = p_character_id
            AND option_row.source_type = 'ai'
            AND option_row.is_active IS TRUE
            AND option_row.day_type = v_day_type
            AND option_row.special_event_key IS NULL
            AND option_row.start_time = v_row.start_time
            AND option_row.end_time = v_row.end_time
            AND option_row.variant_key IN ('option_1', 'option_2', 'option_3')
        ) AS weighted
        WHERE weighted.cumulative_weight > v_option_roll
        ORDER BY weighted.cumulative_weight
        LIMIT 1;
        IF v_row.id IS DISTINCT FROM v_selected_schedule_id THEN CONTINUE; END IF;
      END IF;$new$;

  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'hourly_resolver_selection_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$resolver$;

-- Version the source payload. Existing characters regenerate only on their next
-- ordinary enqueue/edit; this migration does not trigger a mass AI generation.
DO $source_version$
DECLARE
  v_definition text;
  v_old text := 'poyozz-encounter-schedule-v5-natural-locations-scene-descriptions-2026-11-18';
  v_new text := 'poyozz-encounter-schedule-v6-hourly-independent-options-2026-11-18';
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.encounter_schedule_source_payload(uuid)'::regprocedure
  ) INTO v_definition;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'encounter_schedule_hourly_source_version_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$source_version$;

COMMENT ON FUNCTION public.resolve_encounter_character_schedule(uuid,uuid,text,timestamptz) IS
  'Resolves a character hourly schedule. New AI schedules select one weighted option independently per date/hour using a stable deterministic seed; old primary/alternative rows remain compatible until regeneration. Rain decisions are persisted per selected schedule occurrence.';

COMMIT;
