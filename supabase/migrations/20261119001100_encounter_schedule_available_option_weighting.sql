BEGIN;

-- When one hourly option points to a scene that is not currently published,
-- remove only that option from the weighted pool. Re-normalize the remaining
-- weights so an unavailable option cannot make the entire hour disappear.
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

  v_old := '  v_selected_schedule_id uuid;';
  v_new := v_old || E'\n  v_available_option_weight integer;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'available_option_weight_variable_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$      ELSE
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
      END IF;$old$;

  v_new := $new$      ELSE
        SELECT COALESCE(pg_catalog.sum(option_row.variant_weight), 0)::integer
          INTO v_available_option_weight
        FROM public.character_schedules option_row
        WHERE option_row.character_id = p_character_id
          AND option_row.source_type = 'ai'
          AND option_row.is_active IS TRUE
          AND option_row.day_type = v_day_type
          AND option_row.special_event_key IS NULL
          AND option_row.start_time = v_row.start_time
          AND option_row.end_time = v_row.end_time
          AND option_row.variant_key IN ('option_1', 'option_2', 'option_3')
          AND EXISTS (
            SELECT 1
            FROM public.get_encounter_scene_catalog() AS available_scene
            WHERE available_scene.location_key = COALESCE(
              option_row.location_key,
              public.resolve_encounter_scene_location_key(option_row.location_description)
            )
          );

        IF v_available_option_weight <= 0 THEN CONTINUE; END IF;

        v_option_roll := pg_catalog.mod(
          pg_catalog.abs(pg_catalog.hashtext(
            p_character_id::text || v_schedule_date::text || v_row.start_time::text || 'hourly-options-v1'
          )::bigint),
          v_available_option_weight
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
            AND EXISTS (
              SELECT 1
              FROM public.get_encounter_scene_catalog() AS available_scene
              WHERE available_scene.location_key = COALESCE(
                option_row.location_key,
                public.resolve_encounter_scene_location_key(option_row.location_description)
              )
            )
        ) AS weighted
        WHERE weighted.cumulative_weight > v_option_roll
        ORDER BY weighted.cumulative_weight
        LIMIT 1;
        IF v_row.id IS DISTINCT FROM v_selected_schedule_id THEN CONTINUE; END IF;
      END IF;$new$;

  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'available_option_weight_selection_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$resolver$;

COMMENT ON FUNCTION public.resolve_encounter_character_schedule(uuid, uuid, text, timestamptz) IS
  'Resolves one stable weighted hourly option from currently published scenes; unavailable options are excluded and remaining weights are renormalized.';

COMMIT;
