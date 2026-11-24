-- Preserve Jiang Chenyuan's existing AI schedules without another provider call.
-- The previous worldview migration re-queued this character solely because the
-- source payload version gained an empty legacy worldview_tags array.
-- Keep all 96 existing schedule rows. Map indoor worksite activity to the existing
-- high-end apartment scene, and reuse existing office/home scenes for known venues.
BEGIN;

DO $repair$
DECLARE
  v_character_id uuid := '19000b3d-6a0a-4266-8248-4acafab82305';
  v_generic_rows integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.characters
    WHERE id = v_character_id
      AND name = '江辰遠'
      AND visibility = 'public'
      AND review_status = 'approved'
      AND rights_confirmed IS TRUE
      AND deleted_at IS NULL
  ) THEN
    -- Disposable CI databases do not contain this TEST character.
    RETURN;
  END IF;

  SELECT count(*) INTO v_generic_rows
  FROM public.character_schedules
  WHERE character_id = v_character_id
    AND source_type = 'ai'
    AND is_active IS TRUE
    AND location_description = '工地'
    AND is_outdoor IS FALSE;

  IF v_generic_rows <> 9 THEN
    RAISE EXCEPTION 'jiang_chengyuan_expected_9_generic_indoor_work_rows_got_%', v_generic_rows;
  END IF;

  UPDATE public.character_schedules
  SET location_description = '高級公寓',
      location_key = 'luxury-apartment',
      updated_at = pg_catalog.now()
  WHERE character_id = v_character_id
    AND source_type = 'ai'
    AND is_active IS TRUE
    AND location_description = '工地'
    AND is_outdoor IS FALSE;

  -- Reuse existing city scenes for the character's known studio, office, and home.
  -- Keep the authored location labels and activities unchanged.
  UPDATE public.character_schedules
  SET location_key = 'commercial',
      updated_at = pg_catalog.now()
  WHERE character_id = v_character_id
    AND source_type = 'ai'
    AND is_active IS TRUE
    AND location_key IS NULL
    AND location_description IN ('事務所', '工作室');

  UPDATE public.character_schedules
  SET location_key = 'apartment',
      updated_at = pg_catalog.now()
  WHERE character_id = v_character_id
    AND source_type = 'ai'
    AND is_active IS TRUE
    AND location_key IS NULL
    AND location_description = '你家';

  -- The nearby lunch stop already resolves to shopping-street and is untouched.
  -- Cancel only the zero-attempt requeue; future real source edits can enqueue again.
  UPDATE public.encounter_schedule_generation_jobs
  SET status = 'cancelled',
      last_error_code = 'preserved_existing_schedule_no_ai',
      lease_token = NULL,
      lease_expires_at = NULL,
      completed_at = NULL,
      updated_at = pg_catalog.now()
  WHERE character_id = v_character_id
    AND status = 'pending'
    AND attempt_count = 0
    AND source_hash = '19c71030f2835739a1b4e9c57df7f083'
    AND last_completed_source_hash = '4424703d84484c1cff255c8bb0d37e15';
END;
$repair$;

COMMIT;
