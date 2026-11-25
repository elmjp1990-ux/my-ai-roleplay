-- Replace legacy test schedules and make AI schedule publication salvage-safe.
-- Test environment only: legacy schedule rows were temporary test data and are removed.
BEGIN;

DELETE FROM public.character_schedules WHERE source_type = 'legacy';

DO $migration$
DECLARE
  v_definition text := pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  );
  v_old text;
  v_new text;
  v_start integer;
  v_end integer;
BEGIN
  -- Remove legacy compatibility from the publish function.
  v_old := $replace$source_type IN ('ai', 'legacy')$replace$;
  IF pg_catalog.strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'expected legacy source compatibility fragment not found';
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, $replace$source_type = 'ai'$replace$);

  -- Do not clear all existing AI schedules before a partial publish.
  -- Remove the modern-map full-clear statement by locating it after the placement guard.
  v_start := pg_catalog.strpos(v_definition, 'IF v_placement <> ''modern_map'' THEN');
  v_start := pg_catalog.strpos(pg_catalog.substring(v_definition, v_start), 'UPDATE public.character_schedules') + v_start - 1;
  IF v_start < 1 THEN
    RAISE EXCEPTION 'full-clear statement not found after modern-map guard';
  END IF;
  v_end := pg_catalog.strpos(pg_catalog.substring(v_definition FROM v_start), ';') + v_start - 1;
  IF v_end < v_start THEN
    RAISE EXCEPTION 'full-clear statement terminator not found';
  END IF;
  v_definition := pg_catalog.substring(v_definition FROM 1 FOR v_start - 1) || pg_catalog.substring(v_definition, v_end + 1);

  -- Replace old AI rows only for the exact day type and hour being published.
  v_old := $replace$      FOR v_variant IN SELECT value FROM jsonb_array_elements(v_item->'variants'->v_day_type)
      LOOP$replace$;
  v_new := $replace$      FOR v_variant IN SELECT value FROM jsonb_array_elements(v_item->'variants'->v_day_type)
      LOOP
        UPDATE public.character_schedules
        SET is_active = false, updated_at = pg_catalog.clock_timestamp()
        WHERE character_id = v_character_id
          AND source_type = 'ai'
          AND is_active IS TRUE
          AND day_type = v_day_type
          AND start_time = (v_variant->>'start_time')::time
          AND end_time = (v_variant->>'end_time')::time;$replace$;
  IF pg_catalog.strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'hour loop insertion point not found';
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  -- Allow sparse 1-24 hour blocks; enforce sorted, non-overlapping hourly blocks.
  v_old := $replace$      IF jsonb_array_length(v_item->'variants'->v_day_type) <> 24 THEN
        RAISE EXCEPTION 'schedule_hourly_blocks_invalid' USING ERRCODE = '22023';
      END IF;

$replace$;
  IF pg_catalog.strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION '24-hour count restriction fragment not found';
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, '');

  v_old := $replace$        IF (v_previous_block_start IS NULL AND v_block_start <> time '00:00')
           OR (v_previous_block_start IS NOT NULL AND v_block_start <> (v_previous_block_start + interval '1 hour')::time) THEN
          RAISE EXCEPTION 'schedule_hourly_blocks_must_cover_contiguous_24_hours' USING ERRCODE = '22023';
        END IF;
        v_previous_block_start := v_block_start;

$replace$;
  IF pg_catalog.strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'contiguous hours restriction fragment not found';
  END IF;
  v_new := $replace$        IF v_previous_block_start IS NOT NULL AND v_block_start <= v_previous_block_start THEN
          RAISE EXCEPTION 'schedule_hourly_blocks_overlap_or_unsorted' USING ERRCODE = '22023';
        END IF;
        v_previous_block_start := v_block_start;

$replace$;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  -- A single valid option is supported; weights must still total 100.
  v_old := $replace$        IF jsonb_array_length(v_variant->'options') NOT BETWEEN 2 AND 3 THEN$replace$;
  IF pg_catalog.strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'option count validation fragment not found';
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old,
    $replace$        IF jsonb_array_length(v_variant->'options') NOT BETWEEN 1 AND 3 THEN$replace$);

  EXECUTE v_definition;
END;
$migration$;

COMMIT;
