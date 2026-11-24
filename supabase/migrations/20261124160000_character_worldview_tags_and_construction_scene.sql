-- Add author-selected worldview categories and feed them into schedule generation.
-- CI replays this after the schedule source and trigger functions exist in its disposable database.
-- Empty arrays preserve legacy inference for characters created before this field existed.
ALTER TABLE public.characters
  ADD COLUMN IF NOT EXISTS worldview_tags text[] NOT NULL DEFAULT ARRAY[]::text[];

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_constraint
    WHERE conname = 'characters_worldview_tags_allowed'
      AND conrelid = 'public.characters'::regclass
  ) THEN
    ALTER TABLE public.characters
      ADD CONSTRAINT characters_worldview_tags_allowed
      CHECK (worldview_tags <@ ARRAY['modern', 'ancient', 'fantasy']::text[]);
  END IF;
END;
$migration$;

-- Keep the schedule source payload in sync without replacing unrelated fields.
DO $migration$
DECLARE
  v_definition text;
  v_marker text := $marker$'tags', COALESCE(pg_catalog.to_jsonb(c.tags), '[]'::jsonb),$marker$;
  v_worldview_marker text := $marker$'worldview_tags', COALESCE(pg_catalog.to_jsonb(c.worldview_tags), '[]'::jsonb),$marker$;
  v_new_version text := 'poyozz-encounter-schedule-v11-worldview-tags-construction-2026-11-24';
  v_old_versions text[] := ARRAY[
    'poyozz-encounter-schedule-v10-modern-context-signals-2026-11-23',
    'poyozz-encounter-schedule-v9-worldview-tags-construction-2026-11-24',
    'poyozz-encounter-schedule-v8-compact-24-hour-options-2026-11-19'
  ];
  v_old_version text;
  v_version_count integer;
  v_version_updated boolean := false;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.encounter_schedule_source_payload(uuid)'::regprocedure
  ) INTO v_definition;

  IF pg_catalog.strpos(v_definition, v_worldview_marker) = 0 THEN
    IF pg_catalog.strpos(v_definition, v_marker) = 0 THEN
      RAISE EXCEPTION 'encounter_schedule_source_payload_tags_marker_not_found';
    END IF;
    v_definition := pg_catalog.replace(
      v_definition,
      v_marker,
      v_marker || E'\n    ''worldview_tags'', COALESCE(pg_catalog.to_jsonb(c.worldview_tags), ''[]''::jsonb),'
    );
  END IF;

  FOREACH v_old_version IN ARRAY v_old_versions LOOP
    SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old_version, '')))
      / pg_catalog.length(v_old_version) INTO v_version_count;
    IF v_version_count = 1 THEN
      v_definition := pg_catalog.replace(v_definition, v_old_version, v_new_version);
      v_version_updated := true;
      EXIT;
    ELSIF v_version_count > 1 THEN
      RAISE EXCEPTION 'encounter_schedule_source_version_marker_duplicated';
    END IF;
  END LOOP;

  IF NOT v_version_updated AND pg_catalog.strpos(v_definition, v_new_version) = 0 THEN
    RAISE EXCEPTION 'encounter_schedule_source_version_contract_unexpected';
  END IF;

  EXECUTE v_definition;
END;
$migration$;-- Re-queue only active AI schedules that used the generic "工地" label.
-- The Edge Function must be deployed before this migration is applied.
DO $requeue$
DECLARE
  v_character_id uuid;
BEGIN
  FOR v_character_id IN
    SELECT DISTINCT character_id
    FROM public.character_schedules
    WHERE source_type = 'ai'
      AND is_active IS TRUE
      AND location_description LIKE '%工地%'
  LOOP
    PERFORM public.enqueue_encounter_schedule_generation_internal(v_character_id);
  END LOOP;
END;
$requeue$;

-- A worldview change must refresh the source hash and enqueue a new schedule.
DROP TRIGGER IF EXISTS characters_enqueue_encounter_schedule_ai ON public.characters;
CREATE TRIGGER characters_enqueue_encounter_schedule_ai
AFTER INSERT OR UPDATE OF author_id, name, title, intro, race, style, gender, age, tags,
  worldview_tags, personality_profile, visibility, review_status, rights_confirmed, deleted_at
ON public.characters
FOR EACH ROW EXECUTE FUNCTION public.on_encounter_character_visibility_changed();

COMMENT ON COLUMN public.characters.worldview_tags IS
  'Author-selected worldview categories: modern, ancient, fantasy. Empty array means legacy inference.';
