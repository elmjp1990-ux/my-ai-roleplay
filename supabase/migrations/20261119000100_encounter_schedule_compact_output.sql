BEGIN;

-- New schedule generations no longer produce greeting paragraphs. Keep the
-- legacy columns readable for old schedules, but allow new rows to omit them.
ALTER TABLE public.character_schedules
  ALTER COLUMN encounter_greeting DROP NOT NULL;

COMMENT ON COLUMN public.character_schedules.encounter_greeting IS
  'Legacy generated greeting; new Encounter turns generate their opening response dynamically and leave this column NULL.';
COMMENT ON COLUMN public.character_schedules.rain_fallback_greeting IS
  'Legacy rain fallback greeting; new schedule generations store only the rain fallback location and activity.';

-- Keep the existing publisher and its lease/authorization behavior, while
-- adapting only the schedule payload contract to concise 24-hour options.
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

  v_old := '  v_previous_block_start time;';
  v_new := v_old || E'\n  v_multi_option_hours integer := 0;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_publisher_variable_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  -- Relationship greeting pools are no longer generated. Delete stale pools
  -- atomically with publishing the new schedule instead of requiring model text.
  v_old := '    v_greeting_pool := v_item->''relationship_greetings'';';
  v_start := pg_catalog.strpos(v_definition, v_old);
  v_new := '    DELETE FROM public.encounter_character_greeting_pools WHERE character_id = v_character_id;' || E'\n\n';
  v_old := '    UPDATE public.character_schedules' || E'\n' ||
    '    SET is_active = false, updated_at = pg_catalog.clock_timestamp()' || E'\n' ||
    '    WHERE character_id = v_character_id AND source_type IN (''ai'', ''legacy'') AND is_active IS TRUE;';
  v_end := pg_catalog.strpos(pg_catalog.substr(v_definition, v_start), v_old) + v_start - 1;
  IF v_start = 0 OR v_end < v_start THEN
    RAISE EXCEPTION 'compact_publisher_relationship_pool_validation_boundaries_missing';
  END IF;
  v_definition := pg_catalog.substr(v_definition, 1, v_start - 1)
    || v_new
    || pg_catalog.substr(v_definition, v_end);

  -- The old pool upsert is now obsolete; the stale pool was deleted above.
  v_old := '    INSERT INTO public.encounter_character_greeting_pools (' || E'\n' ||
    '      character_id, source_hash, greeting_pools, generated_at, updated_at' || E'\n' ||
    '    ) VALUES (' || E'\n' ||
    '      v_character_id, v_job.source_hash, v_greeting_pool,' || E'\n' ||
    '      pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()' || E'\n' ||
    '    )' || E'\n' ||
    '    ON CONFLICT (character_id) DO UPDATE' || E'\n' ||
    '    SET source_hash = EXCLUDED.source_hash,' || E'\n' ||
    '        greeting_pools = EXCLUDED.greeting_pools,' || E'\n' ||
    '        generated_at = EXCLUDED.generated_at,' || E'\n' ||
    '        updated_at = EXCLUDED.updated_at;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_publisher_relationship_pool_upsert_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, '');

  -- Both weekday and holiday must contain every hour. The first block starts at
  -- midnight and each next block begins exactly where the previous one ends.
  v_old := '      IF jsonb_array_length(v_item->''variants''->v_day_type) > 24 THEN';
  v_new := '      IF jsonb_array_length(v_item->''variants''->v_day_type) <> 24 THEN';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_publisher_24_hour_count_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := '        IF v_previous_block_start IS NOT NULL AND v_block_start <= v_previous_block_start THEN' || E'\n' ||
    '          RAISE EXCEPTION ''schedule_hourly_blocks_must_be_sorted_and_unique'' USING ERRCODE = ''22023'';' || E'\n' ||
    '        END IF;';
  v_new := '        IF (v_previous_block_start IS NULL AND v_block_start <> time ''00:00'')' || E'\n' ||
    '           OR (v_previous_block_start IS NOT NULL AND v_block_start <> (v_previous_block_start + interval ''1 hour'')::time) THEN' || E'\n' ||
    '          RAISE EXCEPTION ''schedule_hourly_blocks_must_cover_contiguous_24_hours'' USING ERRCODE = ''22023'';' || E'\n' ||
    '        END IF;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_publisher_contiguous_hour_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := '      v_previous_block_start := NULL;';
  v_new := v_old || E'\n      v_multi_option_hours := 0;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_publisher_multi_option_reset_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := '        IF jsonb_array_length(v_variant->''options'') NOT BETWEEN 1 AND 3 THEN' || E'\n' ||
    '          RAISE EXCEPTION ''schedule_hourly_options_count_invalid'' USING ERRCODE = ''22023'';' || E'\n' ||
    '        END IF;';
  v_new := v_old || E'\n' ||
    '        IF jsonb_array_length(v_variant->''options'') >= 2 THEN' || E'\n' ||
    '          v_multi_option_hours := v_multi_option_hours + 1;' || E'\n' ||
    '        END IF;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_publisher_multi_option_count_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := '        IF v_option_weight_total <> 100 THEN' || E'\n' ||
    '          RAISE EXCEPTION ''schedule_hourly_option_weights_must_sum_100'' USING ERRCODE = ''22023'';' || E'\n' ||
    '        END IF;' || E'\n' ||
    '      END LOOP;' || E'\n' ||
    '    END LOOP;';
  v_new := '        IF v_option_weight_total <> 100 THEN' || E'\n' ||
    '          RAISE EXCEPTION ''schedule_hourly_option_weights_must_sum_100'' USING ERRCODE = ''22023'';' || E'\n' ||
    '        END IF;' || E'\n' ||
    '      END LOOP;' || E'\n' ||
    '      IF v_multi_option_hours < 8 THEN' || E'\n' ||
    '        RAISE EXCEPTION ''schedule_hourly_too_few_multi_option_hours'' USING ERRCODE = ''22023'';' || E'\n' ||
    '      END IF;' || E'\n' ||
    '    END LOOP;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_publisher_multi_option_floor_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  -- Activity and rain activity are now deliberately short. Scene description
  -- is populated from activity by the parser for legacy map/UI consumers.
  v_old := '             OR char_length(COALESCE(v_slot->>''activity'', '''')) NOT BETWEEN 1 AND 200';
  v_new := '             OR char_length(COALESCE(v_slot->>''activity'', '''')) NOT BETWEEN 10 AND 30';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_publisher_activity_length_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := '             OR char_length(COALESCE(v_slot->>''encounter_greeting'', '''')) NOT BETWEEN 150 AND 300';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_publisher_encounter_greeting_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, '');

  v_old := '               OR char_length(COALESCE(v_slot->>''rain_fallback_activity'', '''')) NOT BETWEEN 1 AND 200' || E'\n' ||
    '               OR char_length(COALESCE(v_slot->>''rain_fallback_greeting'', '''')) NOT BETWEEN 150 AND 300 THEN';
  v_new := '               OR char_length(COALESCE(v_slot->>''rain_fallback_activity'', '''')) NOT BETWEEN 10 AND 30 THEN';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_publisher_rain_activity_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := '             OR v_slot->>''rain_fallback_activity'' IS NOT NULL' || E'\n' ||
    '             OR v_slot->>''rain_fallback_greeting'' IS NOT NULL THEN';
  v_new := '             OR v_slot->>''rain_fallback_activity'' IS NOT NULL THEN';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_publisher_indoor_rain_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$publisher$;

-- The first encounter response is now generated by encounter-turn. Keep the
-- relationship state (including affinity) but stop selecting a pre-generated
-- greeting from relationship pools or storing a greeting on the session.
DO $session_creator$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_start integer;
  v_end integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.create_encounter_session_with_lifecycle(uuid,uuid,uuid,text,jsonb,jsonb,text,timestamptz,timestamptz)'::regprocedure
  ) INTO v_definition;

  v_old := '  SELECT pools.greeting_pools -> v_relationship_stage';
  v_start := pg_catalog.strpos(v_definition, v_old);
  v_old := '  INSERT INTO public.chat_sessions (';
  v_end := pg_catalog.strpos(pg_catalog.substr(v_definition, v_start), v_old) + v_start - 1;
  IF v_start = 0 OR v_end < v_start THEN
    RAISE EXCEPTION 'compact_encounter_session_greeting_selection_boundaries_missing';
  END IF;

  v_new := '  v_snapshot := COALESCE(p_character_snapshot, ''{}''::jsonb) ||' || E'\n' ||
    '    jsonb_build_object(' || E'\n' ||
    '      ''encounterRelationshipStage'', v_relationship_stage' || E'\n' ||
    '    );' || E'\n' ||
    '  v_session_data := jsonb_build_object(' || E'\n' ||
    '    ''encounter'',' || E'\n' ||
    '    jsonb_build_object(' || E'\n' ||
    '      ''affinity'', v_affinity,' || E'\n' ||
    '      ''relationshipStage'', v_relationship_stage' || E'\n' ||
    '    )' || E'\n' ||
    '  );' || E'\n\n';
  v_definition := pg_catalog.substr(v_definition, 1, v_start - 1)
    || v_new
    || pg_catalog.substr(v_definition, v_end);

  -- Remove the old per-player greeting rotation write.
  v_old := '  IF v_greeting_hash IS NOT NULL THEN';
  v_start := pg_catalog.strpos(v_definition, v_old);
  v_old := '  INSERT INTO public.encounter_session_lifecycle (';
  v_end := pg_catalog.strpos(pg_catalog.substr(v_definition, v_start), v_old) + v_start - 1;
  IF v_start = 0 OR v_end < v_start THEN
    RAISE EXCEPTION 'compact_encounter_session_greeting_history_boundaries_missing';
  END IF;
  v_definition := pg_catalog.substr(v_definition, 1, v_start - 1)
    || pg_catalog.substr(v_definition, v_end);

  EXECUTE v_definition;
END;
$session_creator$;

COMMENT ON FUNCTION public.create_encounter_session_with_lifecycle(uuid,uuid,uuid,text,jsonb,jsonb,text,timestamptz,timestamptz) IS
  'Creates an Encounter session with current affinity and relationship stage; the first AI response is generated dynamically after the player sends a greeting or chooses blank discovery.';

-- Bump the source payload version so the next explicitly requested generation
-- uses the compact schema. This migration does not enqueue jobs or call AI.
DO $source_version$
DECLARE
  v_definition text;
  v_old text := 'poyozz-encounter-schedule-v6-hourly-independent-options-2026-11-18';
  v_new text := 'poyozz-encounter-schedule-v7-compact-24-hour-options-2026-11-19';
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.encounter_schedule_source_payload(uuid)'::regprocedure
  ) INTO v_definition;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'compact_schedule_source_version_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$source_version$;

COMMENT ON FUNCTION public.publish_encounter_schedule_batch(uuid,uuid,jsonb) IS
  'Publishes compact 24-hour weekday/holiday schedules with 1-3 weighted options per hour; schedule greeting text is generated dynamically during an Encounter turn.';

COMMIT;
