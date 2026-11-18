BEGIN;

UPDATE public.character_schedules
SET location_key = 'apartment'
WHERE location_key IS NULL
  AND regexp_replace(pg_catalog.lower(pg_catalog.btrim(COALESCE(location_description, ''))), '\s+', '', 'g')
    IN ('308公寓', '私人公寓', '一般公寓', '普通公寓', '公寓', '住宅', '住家', '住所', '家', '家中', '家裡', '租屋', '租屋處', '套房');

DO $source_version$
DECLARE
  v_definition text;
  v_old text := 'poyozz-encounter-schedule-v6-hourly-independent-options-2026-11-18';
  v_new text := 'poyozz-encounter-schedule-v7-home-mapping-sleep-availability-2026-11-18';
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.encounter_schedule_source_payload(uuid)'::regprocedure
  ) INTO v_definition;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'encounter_schedule_home_mapping_source_version_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$source_version$;

COMMENT ON FUNCTION public.resolve_encounter_character_schedule(uuid,uuid,text,timestamptz) IS
  'Resolves current Taiwan-local hourly schedule. Ordinary residence aliases map to the permanent 308 Apartment marker; the server independently blocks new encounters while the character is sleeping.';

COMMIT;
