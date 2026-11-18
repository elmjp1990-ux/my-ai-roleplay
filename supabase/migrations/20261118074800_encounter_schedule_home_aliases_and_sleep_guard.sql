BEGIN;

-- Service-role-only wrapper returns the exact resolved schedule plus its saved
-- scene description, without exposing direct schedule-table reads to Edge code.
CREATE OR REPLACE FUNCTION public.resolve_encounter_character_schedule_with_scene(
  p_character_id uuid,
  p_user_id uuid,
  p_location_key text,
  p_at timestamptz
)
RETURNS TABLE (
  schedule_id uuid,
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
  scene_description text,
  priority smallint,
  source_type text,
  variant_key text,
  variant_weight smallint,
  encounter_greeting text,
  is_outdoor boolean,
  rain_fallback_location_key text,
  rain_fallback_activity text,
  rain_fallback_greeting text,
  scheduled_start_at timestamptz,
  scheduled_end_at timestamptz
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $
  SELECT
    resolved.schedule_id,
    resolved.weekday,
    resolved.day_type,
    resolved.start_time,
    resolved.end_time,
    resolved.location_key,
    resolved.activity,
    schedule.scene_description,
    resolved.priority,
    resolved.source_type,
    resolved.variant_key,
    resolved.variant_weight,
    resolved.encounter_greeting,
    resolved.is_outdoor,
    resolved.rain_fallback_location_key,
    resolved.rain_fallback_activity,
    resolved.rain_fallback_greeting,
    resolved.scheduled_start_at,
    resolved.scheduled_end_at
  FROM public.resolve_encounter_character_schedule(
    p_character_id, p_user_id, p_location_key, p_at
  ) AS resolved
  JOIN public.character_schedules AS schedule
    ON schedule.id = resolved.schedule_id;
$;

REVOKE ALL ON FUNCTION public.resolve_encounter_character_schedule_with_scene(uuid,uuid,text,timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_encounter_character_schedule_with_scene(uuid,uuid,text,timestamptz)
  TO service_role;

COMMENT ON FUNCTION public.resolve_encounter_character_schedule_with_scene(uuid,uuid,text,timestamptz) IS
  'Service-role-only wrapper returning the authoritative resolved Encounter schedule and its saved scene description for server-side availability checks.';

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
