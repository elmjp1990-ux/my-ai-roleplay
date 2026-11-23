BEGIN;

-- Manual CSV schedules can contain weighted alternatives for the same hour.
-- Keep source_type='manual' for provenance, but resolve option_1..option_3
-- with the same deterministic weighted selection used by AI-published rows.
DO $manual_weighted_options$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.resolve_encounter_character_schedule(uuid,uuid,text,timestamp with time zone)'::regprocedure
  ) INTO v_definition;

  v_old := 'ELSIF v_row.source_type = ''ai'' THEN';
  v_new := 'ELSIF v_row.source_type = ''ai'' OR v_row.variant_key IN (''option_1'', ''option_2'', ''option_3'') THEN';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'manual_weighted_schedule_branch_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := 'AND option_row.source_type = ''ai''';
  v_new := 'AND option_row.source_type = v_row.source_type';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'manual_weighted_schedule_source_filter_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$manual_weighted_options$;

COMMIT;
