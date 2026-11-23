-- Fix the schedule publisher's object key count checks.
-- PostgreSQL exposes jsonb_object_keys(), not jsonb_object_length().
-- Preserve the existing publisher's validation and lease semantics unchanged.
DO $$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  v_old := 'jsonb_object_length(v_variant)';
  v_new := '(SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_object_keys(v_variant))';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'schedule_publisher_variant_key_count_patch_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := 'jsonb_object_length(v_slot)';
  v_new := '(SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_object_keys(v_slot))';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'schedule_publisher_option_key_count_patch_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$$;
