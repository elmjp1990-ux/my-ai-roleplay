-- DRAFT ONLY: Encounter schedule AI pipeline.
-- Do not apply directly to a hosted project. After review, create the migration
-- with `supabase migration new encounter_schedule_pipeline`, move this SQL into
-- the generated migration, and validate on disposable local Supabase first.

BEGIN;

CREATE TABLE IF NOT EXISTS public.encounter_character_greeting_pools (
  character_id uuid PRIMARY KEY REFERENCES public.characters(id) ON DELETE CASCADE,
  source_hash text NOT NULL CHECK (source_hash ~ '^[0-9a-f]{32}
  character_id uuid PRIMARY KEY REFERENCES public.characters(id) ON DELETE CASCADE,
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  source_hash text NOT NULL,
  last_completed_source_hash text,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'failed', 'needs_reconciliation', 'completed', 'cancelled')),
  queued_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  available_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  attempt_count smallint NOT NULL DEFAULT 0 CHECK (attempt_count BETWEEN 0 AND 100),
  lease_token uuid,
  lease_expires_at timestamptz,
  lease_generation bigint NOT NULL DEFAULT 0,
  last_error_code text,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

CREATE INDEX IF NOT EXISTS encounter_schedule_jobs_ready_idx
  ON public.encounter_schedule_generation_jobs (status, available_at, queued_at);

CREATE TABLE IF NOT EXISTS public.encounter_schedule_batch_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lease_token uuid NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'processing'
    CHECK (status IN ('processing', 'completed', 'failed', 'needs_reconciliation', 'cancelled')),
  character_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  actor_user_id uuid,
  is_manual boolean NOT NULL DEFAULT false,
  started_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  completed_at timestamptz,
  failure_code text,
  published_character_count integer NOT NULL DEFAULT 0,
  unplaced_character_count integer NOT NULL DEFAULT 0,
  skipped_character_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

CREATE INDEX IF NOT EXISTS encounter_schedule_batch_runs_started_idx
  ON public.encounter_schedule_batch_runs (started_at DESC);

CREATE TABLE IF NOT EXISTS public.encounter_schedule_generation_usage (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.encounter_schedule_batch_runs(id) ON DELETE CASCADE,
  requested_model text NOT NULL,
  provider text NOT NULL,
  status text NOT NULL,
  usage jsonb NOT NULL DEFAULT '{}'::jsonb,
  gateway_request_id text,
  failure_code text,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

ALTER TABLE public.character_schedules
  ADD COLUMN IF NOT EXISTS source_type text NOT NULL DEFAULT 'legacy',
  ADD COLUMN IF NOT EXISTS variant_key text NOT NULL DEFAULT 'primary',
  ADD COLUMN IF NOT EXISTS variant_weight smallint NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS special_event_key text,
  ADD COLUMN IF NOT EXISTS encounter_greeting text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS is_outdoor boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS rain_fallback_location_key text,
  ADD COLUMN IF NOT EXISTS rain_fallback_activity text,
  ADD COLUMN IF NOT EXISTS rain_fallback_greeting text,
  ADD COLUMN IF NOT EXISTS batch_id uuid REFERENCES public.encounter_schedule_batch_runs(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS source_hash text;

ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_day_type_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_day_type_check
  CHECK (day_type IN ('any', 'weekday', 'weekend', 'holiday'));

ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_source_type_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_source_type_check
  CHECK (source_type IN ('legacy', 'manual', 'ai'));
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_variant_key_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_variant_key_check
  CHECK (variant_key IN ('primary', 'alternative', 'special'));
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_special_event_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_special_event_check
  CHECK (
    (variant_key = 'special'
      AND special_event_key IN ('taiwan_public_holiday', 'lunar_new_year', 'valentines_day', 'christmas')
      AND day_type = 'any'
      AND variant_weight = 100)
    OR (variant_key IN ('primary', 'alternative') AND special_event_key IS NULL)
  );
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_variant_weight_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_variant_weight_check
  CHECK (variant_weight BETWEEN 0 AND 100);
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_encounter_greeting_length_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_encounter_greeting_length_check
  CHECK (encounter_greeting = '' OR char_length(encounter_greeting) BETWEEN 150 AND 300);
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_rain_fallback_consistency_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_rain_fallback_consistency_check
  CHECK (
    (is_outdoor IS TRUE
      AND rain_fallback_location_key IS NOT NULL
      AND rain_fallback_activity IS NOT NULL
      AND rain_fallback_greeting IS NOT NULL
      AND char_length(rain_fallback_greeting) BETWEEN 150 AND 300)
    OR
    (is_outdoor IS FALSE
      AND rain_fallback_location_key IS NULL
      AND rain_fallback_activity IS NULL
      AND rain_fallback_greeting IS NULL)
  );

CREATE INDEX IF NOT EXISTS character_schedules_current_variant_idx
  ON public.character_schedules (character_id, is_active, day_type, variant_key, start_time)
  WHERE is_active IS TRUE;

CREATE INDEX IF NOT EXISTS character_schedules_special_event_idx
  ON public.character_schedules (character_id, special_event_key, start_time)
  WHERE is_active IS TRUE AND special_event_key IS NOT NULL;

-- Freeze the weather fallback selected for a specific occurrence of a schedule.
-- A weather change during the slot must not move an active encounter mid-scene.
CREATE TABLE IF NOT EXISTS public.encounter_schedule_weather_decisions (
  schedule_id uuid NOT NULL REFERENCES public.character_schedules(id) ON DELETE CASCADE,
  scheduled_start_at timestamptz NOT NULL,
  scheduled_end_at timestamptz NOT NULL,
  location_key text NOT NULL,
  activity text NOT NULL,
  encounter_greeting text NOT NULL DEFAULT '',
  is_outdoor boolean NOT NULL DEFAULT false,
  decided_weather_text text NOT NULL DEFAULT '多雲',
  decided_is_raining boolean NOT NULL DEFAULT false,
  decided_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (schedule_id, scheduled_start_at),
  CHECK (scheduled_end_at > scheduled_start_at)
);
CREATE INDEX IF NOT EXISTS encounter_schedule_weather_decisions_end_idx
  ON public.encounter_schedule_weather_decisions (scheduled_end_at);
REVOKE ALL ON TABLE public.encounter_schedule_weather_decisions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.encounter_schedule_weather_decisions TO service_role;

CREATE TABLE IF NOT EXISTS public.taiwan_calendar_days (
  calendar_date date PRIMARY KEY,
  day_type text NOT NULL CHECK (day_type IN ('holiday', 'workday')),
  holiday_name text,
  source text NOT NULL DEFAULT 'government_calendar',
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

ALTER TABLE public.taiwan_calendar_days
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT pg_catalog.now();

-- Older sync versions copied holidaycategory (e.g. "週末假期") into holiday_name.
-- Clear those generic labels so weekends never trigger special-event schedules.
UPDATE public.taiwan_calendar_days
SET holiday_name = NULL,
    updated_at = pg_catalog.now()
WHERE pg_catalog.btrim(COALESCE(holiday_name, '')) ~
  '^(週末假期|周末假期|週末假期等|周末假期等|星期六|星期日|週六|週日|放假|放假日|休假日|假日|例假日)$';

CREATE TABLE IF NOT EXISTS public.encounter_city_weather (
  city_key text PRIMARY KEY CHECK (city_key = 'taipei'),
  weather_text text NOT NULL DEFAULT '天氣資料待更新',
  temperature_c numeric(4,1),
  precipitation_1h_mm numeric(6,1),
  is_raining boolean NOT NULL DEFAULT false,
  observed_at timestamptz,
  fetched_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  source text NOT NULL DEFAULT 'poyozz_fictional_seasonal',
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

ALTER TABLE public.encounter_city_weather ALTER COLUMN source SET DEFAULT 'poyozz_fictional_seasonal';

UPDATE public.encounter_city_weather
SET weather_text = '多雲',
    temperature_c = 24,
    precipitation_1h_mm = NULL,
    is_raining = false,
    observed_at = pg_catalog.now(),
    fetched_at = pg_catalog.now(),
    source = 'poyozz_fallback',
    updated_at = pg_catalog.now()
WHERE source IS DISTINCT FROM 'poyozz_fictional_seasonal'
  AND source IS DISTINCT FROM 'poyozz_fallback';



CREATE INDEX IF NOT EXISTS encounter_city_weather_fetched_idx
  ON public.encounter_city_weather (fetched_at DESC);

CREATE TABLE IF NOT EXISTS public.encounter_scene_registry (
  location_key text PRIMARY KEY,
  display_name text NOT NULL,
  icon text NOT NULL,
  marker_x integer NOT NULL,
  marker_y integer NOT NULL,
  heading text NOT NULL,
  description text NOT NULL,
  event_label text NOT NULL DEFAULT '場景亮點',
  event_title text NOT NULL,
  event_description text NOT NULL,
  is_dynamic boolean NOT NULL DEFAULT false,
  minimum_character_count smallint NOT NULL DEFAULT 1 CHECK (minimum_character_count BETWEEN 1 AND 100),
  display_order smallint NOT NULL DEFAULT 100,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CHECK (marker_x BETWEEN 40 AND 1622),
  CHECK (marker_y BETWEEN 40 AND 892),
  CHECK (is_dynamic IS FALSE OR location_key IN ('shopping-street'))
);

-- V1 allows one controlled dynamic scene type. The AI can propose this key,
-- but never supplies marker coordinates or arbitrary display metadata.
INSERT INTO public.encounter_scene_registry (
  location_key, display_name, icon, marker_x, marker_y,
  heading, description, event_label, event_title, event_description,
  is_dynamic, minimum_character_count, display_order, is_active
) VALUES (
  'shopping-street', '商店街', '🛍️', 1230, 620,
  '沿著街道慢慢逛，遇見城市日常',
  '街邊店舖、櫥窗與行人交織成熱鬧的生活場景。角色可以在不同店家之間移動，也能在街角停下來與熟悉的人碰面。',
  '場景亮點', '街角的偶遇',
  '適合逛街、採買、散步、朋友同行或在店家之間自然相遇。',
  true, 2, 10, true
)
ON CONFLICT (location_key) DO UPDATE
SET display_name = EXCLUDED.display_name,
    icon = EXCLUDED.icon,
    marker_x = EXCLUDED.marker_x,
    marker_y = EXCLUDED.marker_y,
    heading = EXCLUDED.heading,
    description = EXCLUDED.description,
    event_label = EXCLUDED.event_label,
    event_title = EXCLUDED.event_title,
    event_description = EXCLUDED.event_description,
    is_dynamic = EXCLUDED.is_dynamic,
    minimum_character_count = EXCLUDED.minimum_character_count,
    display_order = EXCLUDED.display_order,
    is_active = EXCLUDED.is_active,
    updated_at = pg_catalog.clock_timestamp();

CREATE TABLE IF NOT EXISTS public.encounter_scene_backgrounds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  location_key text NOT NULL DEFAULT '*',
  display_name text NOT NULL,
  asset_path text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order smallint NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CHECK (location_key = '*' OR location_key IN (
    'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
    'department-store', 'bookstore', 'cafe', 'park', 'shopping-street'
  )),
  CHECK (asset_path ~ '^([.]/|/)[A-Za-z0-9_./-]+$')
);

INSERT INTO public.encounter_scene_backgrounds (location_key, display_name, asset_path, is_active, sort_order)
SELECT '*', '城市預設場景', './encounter-default-scene.webp', true, 0
WHERE NOT EXISTS (
  SELECT 1 FROM public.encounter_scene_backgrounds
  WHERE location_key = '*' AND asset_path = './encounter-default-scene.webp'
);

CREATE TABLE IF NOT EXISTS public.encounter_turn_visuals (
  message_id uuid PRIMARY KEY REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  session_id uuid NOT NULL REFERENCES public.chat_sessions(id) ON DELETE CASCADE,
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
  illustration_id uuid REFERENCES public.character_illustrations(id) ON DELETE SET NULL,
  scene_background_id uuid REFERENCES public.encounter_scene_backgrounds(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

CREATE INDEX IF NOT EXISTS encounter_turn_visuals_session_idx
  ON public.encounter_turn_visuals (session_id, created_at DESC);
CREATE INDEX IF NOT EXISTS encounter_turn_visuals_character_idx
  ON public.encounter_turn_visuals (character_id, created_at DESC);

ALTER TABLE public.encounter_schedule_generation_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_schedule_batch_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_schedule_generation_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taiwan_calendar_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_city_weather ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_scene_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_scene_backgrounds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_turn_visuals ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.encounter_schedule_generation_jobs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_schedule_batch_runs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_schedule_generation_usage FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.taiwan_calendar_days FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_city_weather FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_scene_registry FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_scene_backgrounds FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_turn_visuals FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_schedule_generation_jobs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_schedule_batch_runs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_schedule_generation_usage TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_city_weather TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_scene_backgrounds TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_turn_visuals TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.taiwan_calendar_days TO service_role;


CREATE OR REPLACE FUNCTION public.encounter_schedule_source_payload(p_character_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'schedule_schema_version', 'poyozz-encounter-schedule-v3-relationship-greetings-2026-11-17',
    'character_id', c.id::text,
    'author_id', c.author_id::text,
    'visibility', c.visibility,
    'review_status', c.review_status,
    'rights_confirmed', c.rights_confirmed,
    'deleted_at', c.deleted_at,
    'name', c.name,
    'title', COALESCE(c.title, ''),
    'intro', COALESCE(c.intro, ''),
    'race', COALESCE(c.race, ''),
    'style', COALESCE(c.style, ''),
    'gender', COALESCE(c.gender, ''),
    'age', COALESCE(c.age::text, ''),
    'tags', COALESCE(pg_catalog.to_jsonb(c.tags), '[]'::jsonb),
    'occupation', COALESCE(c.personality_profile ->> 'occupation', ''),
    'world_era', pg_catalog.concat_ws(' ', c.intro, c.race, c.style),
    'modern_setting_compatible',
      pg_catalog.concat_ws(' ', c.intro, COALESCE(d.description, ''), p.private_info, c.personality_profile::text)
      ~ '(現代世界|現代背景|現代都市|現代社會|現代生活|當代)',
    'time_travel_explicit',
      pg_catalog.concat_ws(' ', c.intro, COALESCE(d.description, ''), p.private_info, c.personality_profile::text)
      ~ '(穿越到現代|穿越至現代|來到現代|時空旅行到現代|穿越現代)',
    'schedule_description', COALESCE(d.description, ''),
    'existing_author_schedules', COALESCE((
      SELECT pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'weekday', s.weekday,
          'day_type', s.day_type,
          'start_time', pg_catalog.to_char(s.start_time, 'HH24:MI'),
          'end_time', pg_catalog.to_char(s.end_time, 'HH24:MI'),
          'location_key', s.location_key,
          'activity', s.activity
        )
        ORDER BY s.priority DESC, s.start_time
      )
      FROM public.character_schedules s
      WHERE s.character_id = c.id
        AND s.source_type = 'manual'
        AND s.is_active IS TRUE
    ), '[]'::jsonb),
    'private_info', COALESCE(p.private_info, ''),
    'personality_profile', COALESCE(c.personality_profile, '{}'::jsonb)
  )
  FROM public.characters c
  LEFT JOIN public.character_schedule_descriptions d
    ON d.character_id = c.id AND d.author_id = c.author_id
  LEFT JOIN public.character_private_info p
    ON p.character_id = c.id AND p.author_id = c.author_id
  WHERE c.id = p_character_id
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL
$$;

REVOKE ALL ON FUNCTION public.encounter_schedule_source_payload(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.encounter_schedule_source_payload(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_encounter_schedule_generation_internal(p_character_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source jsonb;
  v_hash text;
  v_status text;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  v_source := public.encounter_schedule_source_payload(p_character_id);

  IF v_source IS NULL THEN
    UPDATE public.encounter_schedule_generation_jobs
    SET status = 'cancelled', lease_token = NULL, lease_expires_at = NULL,
        last_error_code = 'character_not_public_or_schedule_missing',
        updated_at = v_now
    WHERE character_id = p_character_id;

    UPDATE public.character_schedules
    SET is_active = false, updated_at = v_now
    WHERE character_id = p_character_id AND source_type = 'ai' AND is_active IS TRUE;

    RETURN pg_catalog.jsonb_build_object('status', 'not_eligible');
  END IF;

  v_hash := pg_catalog.md5(v_source::text);
  INSERT INTO public.encounter_schedule_generation_jobs (
    character_id, author_id, source_hash, status, queued_at, available_at,
    attempt_count, lease_token, lease_expires_at, lease_generation,
    last_error_code, completed_at, updated_at
  ) VALUES (
    p_character_id, (v_source->>'author_id')::uuid, v_hash, 'pending',
    v_now, v_now, 0, NULL, NULL, 1, NULL, NULL, v_now
  )
  ON CONFLICT (character_id) DO UPDATE
  SET author_id = EXCLUDED.author_id,
      source_hash = EXCLUDED.source_hash,
      status = 'pending',
      queued_at = CASE
        WHEN public.encounter_schedule_generation_jobs.status IN
          ('pending', 'processing', 'failed', 'needs_reconciliation')
          THEN public.encounter_schedule_generation_jobs.queued_at
        ELSE v_now
      END,
      available_at = v_now,
      attempt_count = 0,
      lease_token = NULL,
      lease_expires_at = NULL,
      lease_generation = public.encounter_schedule_generation_jobs.lease_generation + 1,
      last_error_code = NULL,
      completed_at = NULL,
      updated_at = v_now
  WHERE public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash
     OR public.encounter_schedule_generation_jobs.status = 'cancelled'
  RETURNING status INTO v_status;

  IF v_status IS NULL THEN
    SELECT status INTO v_status
    FROM public.encounter_schedule_generation_jobs
    WHERE character_id = p_character_id;
  END IF;

  RETURN pg_catalog.jsonb_build_object('status', COALESCE(v_status, 'pending'));
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_encounter_schedule_generation_internal(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.enqueue_encounter_schedule_generation(p_character_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR public.account_is_active() IS NOT TRUE THEN
    RAISE EXCEPTION 'active_authentication_required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.characters c
    WHERE c.id = p_character_id AND c.author_id = v_uid AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'character_not_found_or_not_owned' USING ERRCODE = '42501';
  END IF;

  RETURN public.enqueue_encounter_schedule_generation_internal(p_character_id);
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_encounter_schedule_generation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_encounter_schedule_generation(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.on_encounter_schedule_description_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_character_id uuid;
BEGIN
  v_character_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.character_id ELSE NEW.character_id END;
  PERFORM public.enqueue_encounter_schedule_generation_internal(v_character_id);
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.on_encounter_schedule_description_changed()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS character_schedule_descriptions_enqueue_ai ON public.character_schedule_descriptions;
CREATE TRIGGER character_schedule_descriptions_enqueue_ai
AFTER INSERT OR UPDATE OF description, author_id OR DELETE
ON public.character_schedule_descriptions
FOR EACH ROW EXECUTE FUNCTION public.on_encounter_schedule_description_changed();

CREATE OR REPLACE FUNCTION public.on_encounter_character_visibility_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.enqueue_encounter_schedule_generation_internal(NEW.id);
    RETURN NEW;
  END IF;

  IF OLD.author_id IS DISTINCT FROM NEW.author_id
     OR OLD.name IS DISTINCT FROM NEW.name
     OR OLD.title IS DISTINCT FROM NEW.title
     OR OLD.intro IS DISTINCT FROM NEW.intro
     OR OLD.race IS DISTINCT FROM NEW.race
     OR OLD.style IS DISTINCT FROM NEW.style
     OR OLD.gender IS DISTINCT FROM NEW.gender
     OR OLD.age IS DISTINCT FROM NEW.age
     OR OLD.tags IS DISTINCT FROM NEW.tags
     OR OLD.personality_profile IS DISTINCT FROM NEW.personality_profile
     OR OLD.visibility IS DISTINCT FROM NEW.visibility
     OR OLD.review_status IS DISTINCT FROM NEW.review_status
     OR OLD.rights_confirmed IS DISTINCT FROM NEW.rights_confirmed
     OR OLD.deleted_at IS DISTINCT FROM NEW.deleted_at THEN
    PERFORM public.enqueue_encounter_schedule_generation_internal(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.on_encounter_character_visibility_changed()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS characters_enqueue_encounter_schedule_ai ON public.characters;
CREATE TRIGGER characters_enqueue_encounter_schedule_ai
AFTER INSERT OR UPDATE OF author_id, name, title, intro, race, style, gender, age, tags,
  personality_profile, visibility, review_status, rights_confirmed, deleted_at
ON public.characters
FOR EACH ROW EXECUTE FUNCTION public.on_encounter_character_visibility_changed();

CREATE OR REPLACE FUNCTION public.on_encounter_character_private_info_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_character_id uuid;
BEGIN
  v_character_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.character_id ELSE NEW.character_id END;
  PERFORM public.enqueue_encounter_schedule_generation_internal(v_character_id);
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.on_encounter_character_private_info_changed()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS character_private_info_enqueue_encounter_schedule_ai ON public.character_private_info;
CREATE TRIGGER character_private_info_enqueue_encounter_schedule_ai
AFTER INSERT OR UPDATE OF author_id, private_info OR DELETE
ON public.character_private_info
FOR EACH ROW EXECUTE FUNCTION public.on_encounter_character_private_info_changed();

CREATE OR REPLACE FUNCTION public.claim_encounter_schedule_batch(
  p_limit integer DEFAULT 10,
  p_force boolean DEFAULT false,
  p_actor_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 10);
  v_pending_count integer := 0;
  v_oldest timestamptz;
  v_last_started timestamptz;
  v_day_start timestamptz;
  v_daily_count integer := 0;
  v_lease uuid := gen_random_uuid();
  v_batch uuid;
  v_ids uuid[];
  v_characters jsonb;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('poyozz_encounter_schedule_batch')::bigint);

  UPDATE public.encounter_schedule_generation_jobs
  SET status = 'needs_reconciliation',
      available_at = v_now + interval '6 hours',
      lease_token = NULL,
      lease_expires_at = NULL,
      last_error_code = 'worker_lease_expired',
      updated_at = v_now
  WHERE status = 'processing'
    AND lease_expires_at IS NOT NULL
    AND lease_expires_at < v_now;

  UPDATE public.encounter_schedule_batch_runs
  SET status = 'needs_reconciliation',
      failure_code = COALESCE(failure_code, 'worker_lease_expired'),
      updated_at = v_now
  WHERE status = 'processing'
    AND started_at < v_now - interval '20 minutes';

  SELECT COUNT(DISTINCT j.character_id), MIN(j.queued_at)
  INTO v_pending_count, v_oldest
  FROM public.encounter_schedule_generation_jobs j
  JOIN public.characters c ON c.id = j.character_id
  LEFT JOIN public.character_schedule_descriptions d
    ON d.character_id = j.character_id AND d.author_id = j.author_id
  WHERE j.status IN ('pending', 'failed', 'needs_reconciliation')
    AND (p_force IS TRUE OR j.available_at <= v_now)
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL;

  IF p_force IS NOT TRUE THEN
    IF v_pending_count < 10
       AND (v_oldest IS NULL OR v_oldest > v_now - interval '23 hours 45 minutes') THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'waiting_threshold',
        'pending_character_count', v_pending_count,
        'oldest_queued_at', v_oldest
      );
    END IF;

    v_day_start := (
      pg_catalog.date_trunc('day', v_now AT TIME ZONE 'Asia/Taipei')
      AT TIME ZONE 'Asia/Taipei'
    );
    SELECT COUNT(*) INTO v_daily_count
    FROM public.encounter_schedule_batch_runs b
    WHERE b.started_at >= v_day_start;

    IF v_daily_count >= 4 THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'daily_limit',
        'pending_character_count', v_pending_count,
        'next_eligible_at', v_day_start + interval '1 day'
      );
    END IF;

    SELECT MAX(b.started_at) INTO v_last_started
    FROM public.encounter_schedule_batch_runs b;
    IF v_last_started IS NOT NULL AND v_last_started > v_now - interval '6 hours' THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'cooldown',
        'pending_character_count', v_pending_count,
        'next_eligible_at', v_last_started + interval '6 hours'
      );
    END IF;
  END IF;

  WITH candidates AS (
    SELECT j.character_id
    FROM public.encounter_schedule_generation_jobs j
    JOIN public.characters c ON c.id = j.character_id
    LEFT JOIN public.character_schedule_descriptions d
      ON d.character_id = j.character_id AND d.author_id = j.author_id
    WHERE j.status IN ('pending', 'failed', 'needs_reconciliation')
      AND (p_force IS TRUE OR j.available_at <= v_now)
      AND (p_force IS TRUE OR j.attempt_count < 3 OR j.status = 'needs_reconciliation')
      AND c.visibility = 'public'
      AND c.review_status = 'approved'
      AND c.rights_confirmed IS TRUE
      AND c.deleted_at IS NULL
    ORDER BY j.queued_at, j.character_id
    LIMIT v_limit
    FOR UPDATE OF j SKIP LOCKED
  ),
  claimed AS (
    UPDATE public.encounter_schedule_generation_jobs j
    SET status = 'processing',
        lease_token = v_lease,
        lease_expires_at = v_now + interval '20 minutes',
        lease_generation = j.lease_generation + 1,
        attempt_count = j.attempt_count + 1,
        updated_at = v_now
    FROM candidates c
    WHERE j.character_id = c.character_id
    RETURNING j.character_id
  )
  SELECT pg_catalog.array_agg(character_id ORDER BY character_id)
  INTO v_ids
  FROM claimed;

  IF COALESCE(pg_catalog.cardinality(v_ids), 0) = 0 THEN
    RETURN pg_catalog.jsonb_build_object('status', 'no_pending_jobs', 'pending_character_count', v_pending_count);
  END IF;

  INSERT INTO public.encounter_schedule_batch_runs (
    lease_token, status, character_ids, actor_user_id, is_manual, started_at, updated_at
  ) VALUES (
    v_lease, 'processing', v_ids, p_actor_user_id, p_force IS TRUE, v_now, v_now
  )
  RETURNING id INTO v_batch;

  SELECT pg_catalog.jsonb_agg(public.encounter_schedule_source_payload(x.character_id))
  INTO v_characters
  FROM pg_catalog.unnest(v_ids) AS x(character_id);

  RETURN pg_catalog.jsonb_build_object(
    'status', 'claimed',
    'batch_id', v_batch,
    'lease_token', v_lease,
    'characters', COALESCE(v_characters, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.claim_encounter_schedule_batch(integer, boolean, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_encounter_schedule_batch(integer, boolean, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.fail_encounter_schedule_batch(
  p_batch_id uuid,
  p_lease_token uuid,
  p_failure_code text,
  p_retryable boolean DEFAULT false,
  p_ambiguous boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_batch public.encounter_schedule_batch_runs%ROWTYPE;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_batch
  FROM public.encounter_schedule_batch_runs b
  WHERE b.id = p_batch_id
    AND b.lease_token = p_lease_token
    AND b.status = 'processing'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE public.encounter_schedule_generation_jobs j
  SET status = CASE
        WHEN p_ambiguous IS TRUE THEN 'needs_reconciliation'
        WHEN p_retryable IS TRUE AND j.attempt_count < 3 THEN 'pending'
        ELSE 'failed'
      END,
      available_at = CASE
        WHEN p_ambiguous IS TRUE THEN pg_catalog.clock_timestamp() + interval '6 hours'
        WHEN p_retryable IS TRUE AND j.attempt_count < 3
          THEN pg_catalog.clock_timestamp() + (interval '15 minutes' * GREATEST(j.attempt_count, 1))
        ELSE pg_catalog.clock_timestamp() + interval '24 hours'
      END,
      lease_token = NULL,
      lease_expires_at = NULL,
      last_error_code = LEFT(COALESCE(p_failure_code, 'unknown'), 100),
      updated_at = pg_catalog.clock_timestamp()
  WHERE j.character_id = ANY(v_batch.character_ids)
    AND j.lease_token = p_lease_token
    AND j.status = 'processing';

  UPDATE public.encounter_schedule_batch_runs
  SET status = CASE WHEN p_ambiguous IS TRUE THEN 'needs_reconciliation' ELSE 'failed' END,
      failure_code = LEFT(COALESCE(p_failure_code, 'unknown'), 100),
      completed_at = pg_catalog.clock_timestamp(),
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = p_batch_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.fail_encounter_schedule_batch(uuid, uuid, text, boolean, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_encounter_schedule_batch(uuid, uuid, text, boolean, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.publish_encounter_schedule_batch(
  p_batch_id uuid,
  p_lease_token uuid,
  p_characters jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_batch public.encounter_schedule_batch_runs%ROWTYPE;
  v_item jsonb;
  v_variant jsonb;
  v_slot jsonb;
  v_special_event jsonb;
  v_special_slot jsonb;
  v_special_event_key text;
  v_special_event_name text;
  v_character_id uuid;
  v_job public.encounter_schedule_generation_jobs%ROWTYPE;
  v_source jsonb;
  v_current_hash text;
  v_placement text;
  v_greeting_pool jsonb;
  v_day_type text;
  v_published integer := 0;
  v_unplaced integer := 0;
  v_skipped integer := 0;
  v_output_count integer := 0;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_characters) <> 'array' THEN
    RAISE EXCEPTION 'schedule_batch_output_must_be_array' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_batch
  FROM public.encounter_schedule_batch_runs b
  WHERE b.id = p_batch_id AND b.lease_token = p_lease_token AND b.status = 'processing'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_batch_lease_not_found' USING ERRCODE = '40001';
  END IF;

  SELECT COUNT(*) INTO v_output_count FROM jsonb_array_elements(p_characters);
  IF v_output_count <> pg_catalog.cardinality(v_batch.character_ids) THEN
    RAISE EXCEPTION 'schedule_batch_character_count_mismatch' USING ERRCODE = '22023';
  END IF;

  IF (
    SELECT COUNT(DISTINCT value->>'character_id')
    FROM jsonb_array_elements(p_characters)
  ) <> v_output_count THEN
    RAISE EXCEPTION 'schedule_batch_duplicate_character' USING ERRCODE = '22023';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_characters)
  LOOP
    v_character_id := (v_item->>'character_id')::uuid;
    IF NOT (v_character_id = ANY(v_batch.character_ids)) THEN
      RAISE EXCEPTION 'schedule_batch_contains_unclaimed_character' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_job
    FROM public.encounter_schedule_generation_jobs j
    WHERE j.character_id = v_character_id
      AND j.lease_token = p_lease_token
      AND j.status = 'processing'
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'schedule_character_lease_mismatch' USING ERRCODE = '40001';
    END IF;

    v_source := public.encounter_schedule_source_payload(v_character_id);
    IF v_source IS NULL THEN
      UPDATE public.encounter_schedule_generation_jobs
      SET status = 'cancelled', lease_token = NULL, lease_expires_at = NULL,
          last_error_code = 'character_no_longer_public', updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_current_hash := pg_catalog.md5(v_source::text);
    IF v_current_hash IS DISTINCT FROM v_job.source_hash THEN
      UPDATE public.encounter_schedule_generation_jobs
      SET source_hash = v_current_hash, status = 'pending',
          queued_at = pg_catalog.clock_timestamp(), available_at = pg_catalog.clock_timestamp(),
          lease_token = NULL, lease_expires_at = NULL,
          lease_generation = lease_generation + 1, attempt_count = 0,
          last_error_code = 'source_changed_during_generation', updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_placement := v_item->>'placement';
    IF v_placement = 'no_matching_location' THEN
      IF jsonb_typeof(v_item->'special_events') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'unplaced_character_special_events_must_be_empty' USING ERRCODE = '22023';
      END IF;
      IF jsonb_array_length(v_item->'special_events') <> 0 THEN
        RAISE EXCEPTION 'unplaced_character_special_events_must_be_empty' USING ERRCODE = '22023';
      END IF;
      UPDATE public.character_schedules
      SET is_active = false, updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id AND source_type IN ('ai', 'legacy') AND is_active IS TRUE;

      DELETE FROM public.encounter_character_greeting_pools
      WHERE character_id = v_character_id;

      UPDATE public.encounter_schedule_generation_jobs
      SET status = 'completed', last_completed_source_hash = v_job.source_hash,
          completed_at = pg_catalog.clock_timestamp(), lease_token = NULL, lease_expires_at = NULL,
          last_error_code = NULL, updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id;
      v_unplaced := v_unplaced + 1;
      CONTINUE;
    END IF;

    IF v_placement <> 'modern_map' THEN
      RAISE EXCEPTION 'schedule_placement_invalid' USING ERRCODE = '22023';
    END IF;

    v_greeting_pool := v_item->'relationship_greetings';
    IF jsonb_typeof(v_greeting_pool) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'schedule_relationship_greeting_pools_invalid' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(v_greeting_pool)) <> 8
       OR EXISTS (
         SELECT 1
         FROM jsonb_each(v_greeting_pool) AS pool(stage, greetings)
         WHERE pool.stage NOT IN (
           'hostile', 'dislike', 'wary', 'first_meeting',
           'acquaintance', 'close', 'intimate', 'special'
         )
         OR CASE
           WHEN jsonb_typeof(pool.greetings) IS DISTINCT FROM 'array' THEN true
           ELSE jsonb_array_length(pool.greetings) NOT BETWEEN 3 AND 5
             OR EXISTS (
               SELECT 1
               FROM jsonb_array_elements(pool.greetings) AS item(value)
               WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'string'
                  OR pg_catalog.char_length(item.value #>> '{}') NOT BETWEEN 150 AND 300
             )
             OR (
               SELECT count(DISTINCT item.value #>> '{}')
               FROM jsonb_array_elements(pool.greetings) AS item(value)
             ) <> jsonb_array_length(pool.greetings)
         END
       ) THEN
      RAISE EXCEPTION 'schedule_relationship_greeting_pools_invalid' USING ERRCODE = '22023';
    END IF;

    UPDATE public.character_schedules
    SET is_active = false, updated_at = pg_catalog.clock_timestamp()
    WHERE character_id = v_character_id AND source_type IN ('ai', 'legacy') AND is_active IS TRUE;

    FOREACH v_day_type IN ARRAY ARRAY['weekday', 'holiday']::text[]
    LOOP
      IF jsonb_typeof(v_item->'variants'->v_day_type) <> 'array'
         OR jsonb_array_length(v_item->'variants'->v_day_type) <> 2 THEN
        RAISE EXCEPTION 'schedule_variants_invalid' USING ERRCODE = '22023';
      END IF;

      FOR v_variant IN SELECT value FROM jsonb_array_elements(v_item->'variants'->v_day_type)
      LOOP
        IF (v_day_type = 'weekday' AND (
              (v_variant->>'variant_key' = 'primary' AND (v_variant->>'weight')::integer <> 80)
              OR (v_variant->>'variant_key' = 'alternative' AND (v_variant->>'weight')::integer <> 20)
            ))
           OR (v_day_type = 'holiday' AND (
              (v_variant->>'variant_key' = 'primary' AND (v_variant->>'weight')::integer <> 60)
              OR (v_variant->>'variant_key' = 'alternative' AND (v_variant->>'weight')::integer <> 40)
            )) THEN
          RAISE EXCEPTION 'schedule_variant_weight_invalid' USING ERRCODE = '22023';
        END IF;

        IF v_variant->>'variant_key' NOT IN ('primary', 'alternative')
           OR jsonb_typeof(v_variant->'slots') <> 'array'
           OR jsonb_array_length(v_variant->'slots') NOT BETWEEN 2 AND 4 THEN
          RAISE EXCEPTION 'schedule_variant_shape_invalid' USING ERRCODE = '22023';
        END IF;

        FOR v_slot IN SELECT value FROM jsonb_array_elements(v_variant->'slots')
        LOOP
          IF COALESCE(v_slot->>'start_time', '') !~ '^([01][0-9]|2[0-3]):00$'
             OR COALESCE(v_slot->>'end_time', '') !~ '^([01][0-9]|2[0-3]):00$'
             OR v_slot->>'start_time' = v_slot->>'end_time'
             OR COALESCE(v_slot->>'location_key', '') NOT IN (
               'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
               'department-store', 'bookstore', 'cafe', 'park', 'shopping-street'
             )
             OR char_length(COALESCE(v_slot->>'activity', '')) NOT BETWEEN 1 AND 200
             OR char_length(COALESCE(v_slot->>'encounter_greeting', '')) NOT BETWEEN 150 AND 300 THEN
            RAISE EXCEPTION 'schedule_slot_invalid' USING ERRCODE = '22023';
          END IF;

          IF COALESCE((v_slot->>'is_outdoor')::boolean, false) IS TRUE THEN
            IF COALESCE(v_slot->>'rain_fallback_location_key', '') NOT IN (
              'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
              'department-store', 'bookstore', 'cafe'
            )
               OR char_length(COALESCE(v_slot->>'rain_fallback_activity', '')) NOT BETWEEN 1 AND 200
               OR char_length(COALESCE(v_slot->>'rain_fallback_greeting', '')) NOT BETWEEN 150 AND 300 THEN
              RAISE EXCEPTION 'schedule_rain_fallback_invalid' USING ERRCODE = '22023';
            END IF;
          ELSE
            IF v_slot->>'rain_fallback_location_key' IS NOT NULL
               OR v_slot->>'rain_fallback_activity' IS NOT NULL
               OR v_slot->>'rain_fallback_greeting' IS NOT NULL THEN
              RAISE EXCEPTION 'schedule_unexpected_rain_fallback' USING ERRCODE = '22023';
            END IF;
          END IF;

          -- Every daily variant must cover 00:00 through the next 00:00
          -- without gaps. A final 22:00-00:00 slot is represented as a wrap to midnight.
          IF EXISTS (
            WITH intervals AS (
              SELECT
                (EXTRACT(HOUR FROM (slot->>'start_time')::time)::integer * 60) AS start_minute,
                (EXTRACT(HOUR FROM (slot->>'end_time')::time)::integer * 60)
                  + CASE
                      WHEN (slot->>'end_time')::time <= (slot->>'start_time')::time THEN 1440
                      ELSE 0
                    END AS end_minute
              FROM jsonb_array_elements(v_variant->'slots') AS slots(slot)
            ),
            ordered AS (
              SELECT start_minute, end_minute,
                pg_catalog.lag(end_minute) OVER (ORDER BY start_minute) AS previous_end
              FROM intervals
            ),
            coverage AS (
              SELECT
                pg_catalog.count(*) AS slot_count,
                pg_catalog.min(start_minute) AS first_start,
                pg_catalog.max(end_minute) AS final_end,
                pg_catalog.bool_or(previous_end IS NOT NULL AND previous_end <> start_minute) AS has_gap
              FROM ordered
            )
            SELECT 1 FROM coverage
            WHERE slot_count < 2 OR first_start <> 0 OR final_end <> 1440 OR COALESCE(has_gap, true)
          ) THEN
            RAISE EXCEPTION 'schedule_variant_24_hour_coverage_incomplete' USING ERRCODE = '22023';
          END IF;

          INSERT INTO public.character_schedules (
            character_id, weekday, day_type, start_time, end_time, location_key, activity,
            priority, is_active, source_type, variant_key, variant_weight,
            encounter_greeting, is_outdoor, rain_fallback_location_key,
            rain_fallback_activity, rain_fallback_greeting, batch_id, source_hash
          ) VALUES (
            v_character_id, NULL, v_day_type,
            (v_slot->>'start_time')::time, (v_slot->>'end_time')::time,
            v_slot->>'location_key', v_slot->>'activity',
            50, true, 'ai', v_variant->>'variant_key', (v_variant->>'weight')::smallint,
            v_slot->>'encounter_greeting', COALESCE((v_slot->>'is_outdoor')::boolean, false),
            NULLIF(v_slot->>'rain_fallback_location_key', ''),
            NULLIF(v_slot->>'rain_fallback_activity', ''),
            NULLIF(v_slot->>'rain_fallback_greeting', ''),
            p_batch_id, v_job.source_hash
          );
        END LOOP;
      END LOOP;
    END LOOP;

    IF jsonb_typeof(v_item->'special_events') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'schedule_special_events_invalid' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(v_item->'special_events') > 4 THEN
      RAISE EXCEPTION 'schedule_special_events_invalid' USING ERRCODE = '22023';
    END IF;

    IF (
      SELECT COUNT(DISTINCT event.value->>'event_key')
      FROM jsonb_array_elements(v_item->'special_events') AS event(value)
    ) <> jsonb_array_length(v_item->'special_events') THEN
      RAISE EXCEPTION 'schedule_special_event_duplicate' USING ERRCODE = '22023';
    END IF;

    FOR v_special_event IN
      SELECT value FROM jsonb_array_elements(v_item->'special_events')
    LOOP
      v_special_event_key := v_special_event->>'event_key';
      v_special_event_name := pg_catalog.btrim(COALESCE(v_special_event->>'event_name', ''));
      IF COALESCE(v_special_event_key, '') NOT IN ('taiwan_public_holiday', 'lunar_new_year', 'valentines_day', 'christmas')
         OR pg_catalog.char_length(v_special_event_name) NOT BETWEEN 1 AND 40
         OR jsonb_typeof(v_special_event->'slots') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'schedule_special_event_shape_invalid' USING ERRCODE = '22023';
      END IF;
      IF jsonb_array_length(v_special_event->'slots') NOT BETWEEN 2 AND 4 THEN
        RAISE EXCEPTION 'schedule_special_event_shape_invalid' USING ERRCODE = '22023';
      END IF;

      FOR v_special_slot IN
        SELECT value FROM jsonb_array_elements(v_special_event->'slots')
      LOOP
        IF COALESCE(v_special_slot->>'start_time', '') !~ '^([01][0-9]|2[0-3]):00$'
           OR COALESCE(v_special_slot->>'end_time', '') !~ '^([01][0-9]|2[0-3]):00$'
           OR v_special_slot->>'start_time' = v_special_slot->>'end_time'
           OR COALESCE(v_special_slot->>'location_key', '') NOT IN (
             'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
             'department-store', 'bookstore', 'cafe', 'park', 'shopping-street'
           )
           OR pg_catalog.char_length(COALESCE(v_special_slot->>'activity', '')) NOT BETWEEN 1 AND 200
           OR pg_catalog.char_length(COALESCE(v_special_slot->>'encounter_greeting', '')) NOT BETWEEN 150 AND 300
           OR jsonb_typeof(v_special_slot->'is_outdoor') IS DISTINCT FROM 'boolean' THEN
          RAISE EXCEPTION 'schedule_special_event_slot_invalid' USING ERRCODE = '22023';
        END IF;

        IF (v_special_slot->>'is_outdoor')::boolean IS TRUE THEN
          IF COALESCE(v_special_slot->>'rain_fallback_location_key', '') NOT IN (
            'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
            'department-store', 'bookstore', 'cafe'
          )
             OR pg_catalog.char_length(COALESCE(v_special_slot->>'rain_fallback_activity', '')) NOT BETWEEN 1 AND 200
             OR pg_catalog.char_length(COALESCE(v_special_slot->>'rain_fallback_greeting', '')) NOT BETWEEN 150 AND 300 THEN
            RAISE EXCEPTION 'schedule_special_event_rain_fallback_invalid' USING ERRCODE = '22023';
          END IF;
        ELSIF v_special_slot->>'rain_fallback_location_key' IS NOT NULL
           OR v_special_slot->>'rain_fallback_activity' IS NOT NULL
           OR v_special_slot->>'rain_fallback_greeting' IS NOT NULL THEN
          RAISE EXCEPTION 'schedule_special_event_unexpected_rain_fallback' USING ERRCODE = '22023';
        END IF;
      END LOOP;

      IF EXISTS (
        WITH intervals AS (
          SELECT
            EXTRACT(HOUR FROM (slot->>'start_time')::time)::integer * 60 AS start_minute,
            EXTRACT(HOUR FROM (slot->>'end_time')::time)::integer * 60
              + CASE WHEN (slot->>'end_time')::time <= (slot->>'start_time')::time THEN 1440 ELSE 0 END AS end_minute
          FROM jsonb_array_elements(v_special_event->'slots') AS slots(slot)
        ),
        ordered AS (
          SELECT start_minute, end_minute,
            pg_catalog.lag(end_minute) OVER (ORDER BY start_minute) AS previous_end
          FROM intervals
        ),
        coverage AS (
          SELECT pg_catalog.count(*) AS slot_count,
            pg_catalog.min(start_minute) AS first_start,
            pg_catalog.max(end_minute) AS final_end,
            pg_catalog.bool_or(previous_end IS NOT NULL AND previous_end <> start_minute) AS has_gap
          FROM ordered
        )
        SELECT 1 FROM coverage
        WHERE slot_count < 2 OR first_start <> 0 OR final_end <> 1440 OR COALESCE(has_gap, true)
      ) THEN
        RAISE EXCEPTION 'schedule_special_event_24_hour_coverage_incomplete' USING ERRCODE = '22023';
      END IF;

      FOR v_special_slot IN
        SELECT value FROM jsonb_array_elements(v_special_event->'slots')
      LOOP
        INSERT INTO public.character_schedules (
          character_id, weekday, day_type, start_time, end_time, location_key, activity,
          priority, is_active, source_type, variant_key, variant_weight, special_event_key,
          encounter_greeting, is_outdoor, rain_fallback_location_key,
          rain_fallback_activity, rain_fallback_greeting, batch_id, source_hash
        ) VALUES (
          v_character_id, NULL, 'any',
          (v_special_slot->>'start_time')::time, (v_special_slot->>'end_time')::time,
          v_special_slot->>'location_key', v_special_slot->>'activity',
          60, true, 'ai', 'special', 100, v_special_event_key,
          v_special_slot->>'encounter_greeting', (v_special_slot->>'is_outdoor')::boolean,
          NULLIF(v_special_slot->>'rain_fallback_location_key', ''),
          NULLIF(v_special_slot->>'rain_fallback_activity', ''),
          NULLIF(v_special_slot->>'rain_fallback_greeting', ''),
          p_batch_id, v_job.source_hash
        );
      END LOOP;
    END LOOP;

    INSERT INTO public.encounter_character_greeting_pools (
      character_id, source_hash, greeting_pools, generated_at, updated_at
    ) VALUES (
      v_character_id, v_job.source_hash, v_greeting_pool,
      pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
    )
    ON CONFLICT (character_id) DO UPDATE
    SET source_hash = EXCLUDED.source_hash,
        greeting_pools = EXCLUDED.greeting_pools,
        generated_at = EXCLUDED.generated_at,
        updated_at = EXCLUDED.updated_at;

    UPDATE public.encounter_schedule_generation_jobs
    SET status = 'completed', last_completed_source_hash = v_job.source_hash,
        completed_at = pg_catalog.clock_timestamp(), lease_token = NULL, lease_expires_at = NULL,
        last_error_code = NULL, updated_at = pg_catalog.clock_timestamp()
    WHERE character_id = v_character_id;
    v_published := v_published + 1;
  END LOOP;

  UPDATE public.encounter_schedule_batch_runs
  SET status = 'completed', completed_at = pg_catalog.clock_timestamp(),
      published_character_count = v_published, unplaced_character_count = v_unplaced,
      skipped_character_count = v_skipped, updated_at = pg_catalog.clock_timestamp()
  WHERE id = p_batch_id;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'completed',
    'published_character_count', v_published,
    'unplaced_character_count', v_unplaced,
    'skipped_private_character_count', v_skipped
  );
END;
$$;

REVOKE ALL ON FUNCTION public.publish_encounter_schedule_batch(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_encounter_schedule_batch(uuid, uuid, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.resolve_encounter_special_event_key(p_date date)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $encounter_special_event$
  SELECT CASE
    WHEN pg_catalog.to_char(p_date, 'MM-DD') = '02-14' THEN 'valentines_day'
    WHEN pg_catalog.to_char(p_date, 'MM-DD') = '12-25' THEN 'christmas'
    WHEN EXISTS (
      SELECT 1
      FROM public.taiwan_calendar_days d
      WHERE d.calendar_date = p_date
        AND d.day_type = 'holiday'
        AND d.holiday_name ~ '(春節|農曆新年|農曆除夕|除夕)'
    ) THEN 'lunar_new_year'
    WHEN EXISTS (
      SELECT 1
      FROM public.taiwan_calendar_days d
      WHERE d.calendar_date = p_date
        AND d.day_type = 'holiday'
        AND NULLIF(pg_catalog.btrim(d.holiday_name), '') IS NOT NULL
    ) THEN 'taiwan_public_holiday'
    ELSE NULL
  END;
$encounter_special_event$;

REVOKE ALL ON FUNCTION public.resolve_encounter_special_event_key(date)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_encounter_special_event_key(date)
  TO service_role;

COMMENT ON FUNCTION public.resolve_encounter_special_event_key(date) IS
  'Resolves only supported conditional schedule keys: Taiwan official named holidays, Valentine day, and Christmas. Character birthdays remain unsupported until a structured character birthday field exists.';

CREATE OR REPLACE FUNCTION public.resolve_encounter_character_schedule(
  p_character_id uuid,
  p_user_id uuid DEFAULT auth.uid(),
  p_location_key text DEFAULT NULL,
  p_at timestamptz DEFAULT pg_catalog.now()
)
RETURNS TABLE (
  schedule_id uuid,
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
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
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_local timestamp;
  v_local_date date;
  v_local_time time;
  v_schedule_date date;
  v_schedule_day integer;
  v_day_type text;
  v_special_event_key text;
  v_variant_roll integer;
  v_primary_weight integer;
  v_variant_key text;
  v_is_raining boolean := false;
  v_weather_text text := '多雲';
  v_row public.character_schedules%ROWTYPE;
  v_decision public.encounter_schedule_weather_decisions%ROWTYPE;
  v_effective_location text;
  v_effective_activity text;
  v_effective_greeting text;
  v_effective_is_outdoor boolean;
  v_start_local timestamp;
  v_end_local timestamp;
BEGIN
  v_local := p_at AT TIME ZONE 'Asia/Taipei';
  v_local_date := v_local::date;
  v_local_time := v_local::time;
  SELECT weather.is_raining, weather.weather_text
    INTO v_is_raining, v_weather_text
  FROM public.get_encounter_city_weather() AS weather;
  v_is_raining := COALESCE(v_is_raining, false);
  v_weather_text := COALESCE(v_weather_text, '多雲');

  -- Keep only recent decisions; old schedule occurrences are no longer resolvable.
  DELETE FROM public.encounter_schedule_weather_decisions d
  USING public.character_schedules s
  WHERE d.schedule_id = s.id
    AND s.character_id = p_character_id
    AND d.scheduled_end_at < (p_at - interval '2 days');

  FOR v_row IN
    SELECT s.*
    FROM public.characters c
    JOIN public.character_schedules s ON s.character_id = c.id
    WHERE c.id = p_character_id
      AND c.visibility = 'public'
      AND c.deleted_at IS NULL
      AND c.review_status = 'approved'
      AND c.rights_confirmed IS TRUE
      AND (
        c.is_nsfw IS NOT TRUE
        OR EXISTS (
          SELECT 1 FROM public.profiles p
          WHERE p.id = p_user_id
            AND p.birthdate IS NOT NULL
            AND p.birthdate <= (CURRENT_DATE - interval '18 years')::date
        )
      )
      AND s.is_active IS TRUE
      AND (
        (s.start_time < s.end_time AND v_local_time >= s.start_time AND v_local_time < s.end_time)
        OR
        (s.start_time > s.end_time AND (v_local_time >= s.start_time OR v_local_time < s.end_time))
      )
    ORDER BY
      CASE s.source_type WHEN 'manual' THEN 3 WHEN 'ai' THEN 2 ELSE 1 END DESC,
      CASE s.special_event_key
        WHEN 'lunar_new_year' THEN 4
        WHEN 'valentines_day' THEN 4
        WHEN 'christmas' THEN 4
        WHEN 'taiwan_public_holiday' THEN 3
        ELSE 0
      END DESC,
      s.priority DESC,
      s.start_time
  LOOP
    v_schedule_date := CASE
      WHEN v_row.start_time > v_row.end_time AND v_local_time < v_row.end_time
        THEN v_local_date - 1
      ELSE v_local_date
    END;
    v_schedule_day := EXTRACT(DOW FROM v_schedule_date)::integer;

    SELECT CASE
      WHEN d.day_type = 'workday' THEN 'weekday'
      WHEN d.day_type = 'holiday' THEN 'holiday'
      WHEN d.calendar_date IS NULL AND v_schedule_day IN (0, 6) THEN 'holiday'
      ELSE 'weekday'
    END INTO v_day_type
    FROM (SELECT v_schedule_date AS calendar_date) current_day
    LEFT JOIN public.taiwan_calendar_days d ON d.calendar_date = current_day.calendar_date;

    v_special_event_key := public.resolve_encounter_special_event_key(v_schedule_date);
    IF v_row.special_event_key IS NOT NULL THEN
      IF v_row.special_event_key IS DISTINCT FROM v_special_event_key
         AND NOT (
           v_row.special_event_key = 'taiwan_public_holiday'
           AND EXISTS (
             SELECT 1
             FROM public.taiwan_calendar_days d
             WHERE d.calendar_date = v_schedule_date
               AND d.day_type = 'holiday'
               AND NULLIF(pg_catalog.btrim(d.holiday_name), '') IS NOT NULL
           )
         ) THEN
        CONTINUE;
      END IF;
    ELSIF v_row.source_type = 'ai' THEN
      IF v_row.day_type <> v_day_type THEN CONTINUE; END IF;
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
      IF v_row.weekday IS NOT NULL AND v_row.weekday <> v_schedule_day THEN CONTINUE; END IF;
      IF NOT (
        v_row.day_type = 'any'
        OR (v_row.day_type = 'weekday' AND v_day_type = 'weekday')
        OR (v_row.day_type = 'weekend' AND v_schedule_day IN (0, 6))
        OR (v_row.day_type = 'holiday' AND v_day_type = 'holiday')
      ) THEN CONTINUE; END IF;
    END IF;

    v_start_local := v_schedule_date + v_row.start_time;
    v_end_local := v_schedule_date + v_row.end_time
      + CASE WHEN v_row.end_time <= v_row.start_time THEN interval '1 day' ELSE interval '0' END;

    SELECT * INTO v_decision
    FROM public.encounter_schedule_weather_decisions d
    WHERE d.schedule_id = v_row.id
      AND d.scheduled_start_at = (v_start_local AT TIME ZONE 'Asia/Taipei');

    IF NOT FOUND THEN
      v_effective_location := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN COALESCE(v_row.rain_fallback_location_key, v_row.location_key)
        ELSE v_row.location_key END;
      v_effective_activity := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN COALESCE(v_row.rain_fallback_activity, v_row.activity)
        ELSE v_row.activity END;
      v_effective_greeting := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN COALESCE(v_row.rain_fallback_greeting, v_row.encounter_greeting)
        ELSE v_row.encounter_greeting END;
      v_effective_is_outdoor := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN false ELSE v_row.is_outdoor END;

      INSERT INTO public.encounter_schedule_weather_decisions (
        schedule_id, scheduled_start_at, scheduled_end_at, location_key, activity,
        encounter_greeting, is_outdoor, decided_weather_text, decided_is_raining
      ) VALUES (
        v_row.id, (v_start_local AT TIME ZONE 'Asia/Taipei'),
        (v_end_local AT TIME ZONE 'Asia/Taipei'),
        v_effective_location, v_effective_activity, v_effective_greeting,
        v_effective_is_outdoor, v_weather_text, v_is_raining
      ) ON CONFLICT ON CONSTRAINT encounter_schedule_weather_decisions_pkey DO NOTHING;

      SELECT * INTO v_decision
      FROM public.encounter_schedule_weather_decisions d
      WHERE d.schedule_id = v_row.id
        AND d.scheduled_start_at = (v_start_local AT TIME ZONE 'Asia/Taipei');
    END IF;

    IF p_location_key IS NOT NULL AND v_decision.location_key <> p_location_key THEN
      CONTINUE;
    END IF;

    RETURN QUERY SELECT
      v_row.id,
      v_schedule_day::smallint,
      v_day_type,
      v_row.start_time,
      v_row.end_time,
      v_decision.location_key,
      v_decision.activity,
      v_row.priority,
      v_row.source_type,
      v_row.variant_key,
      v_row.variant_weight,
      v_decision.encounter_greeting,
      v_decision.is_outdoor,
      v_row.rain_fallback_location_key,
      v_row.rain_fallback_activity,
      v_row.rain_fallback_greeting,
      v_start_local AT TIME ZONE 'Asia/Taipei',
      v_end_local AT TIME ZONE 'Asia/Taipei';
    RETURN;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_encounter_character_schedule(uuid, uuid, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_encounter_character_schedule(uuid, uuid, text, timestamptz)
  TO service_role;

DROP FUNCTION IF EXISTS public.get_encounter_character_schedule(uuid);
CREATE FUNCTION public.get_encounter_character_schedule(p_character_id uuid)
RETURNS TABLE (
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
  priority smallint,
  encounter_greeting text,
  is_outdoor boolean,
  rain_fallback_location_key text,
  rain_fallback_activity text,
  rain_fallback_greeting text,
  source_type text,
  variant_key text,
  variant_weight smallint
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    r.weekday, r.day_type, r.start_time, r.end_time, r.location_key, r.activity,
    r.priority, r.encounter_greeting, r.is_outdoor, r.rain_fallback_location_key,
    r.rain_fallback_activity, r.rain_fallback_greeting, r.source_type, r.variant_key, r.variant_weight
  FROM public.resolve_encounter_character_schedule(p_character_id, auth.uid(), NULL, pg_catalog.now()) r;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_character_schedule(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_character_schedule(uuid) TO anon, authenticated;

DROP FUNCTION IF EXISTS public.get_encounter_character_schedules(uuid[]);
CREATE FUNCTION public.get_encounter_character_schedules(p_character_ids uuid[])
RETURNS TABLE (
  character_id uuid,
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
  priority smallint,
  encounter_greeting text,
  is_outdoor boolean,
  rain_fallback_location_key text,
  rain_fallback_activity text,
  rain_fallback_greeting text,
  source_type text,
  variant_key text,
  variant_weight smallint
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    ids.character_id,
    r.weekday, r.day_type, r.start_time, r.end_time, r.location_key, r.activity,
    r.priority, r.encounter_greeting, r.is_outdoor, r.rain_fallback_location_key,
    r.rain_fallback_activity, r.rain_fallback_greeting, r.source_type, r.variant_key, r.variant_weight
  FROM (
    SELECT DISTINCT unnest(p_character_ids) AS character_id
  ) ids
  CROSS JOIN LATERAL public.resolve_encounter_character_schedule(
    ids.character_id, auth.uid(), NULL, pg_catalog.now()
  ) r
  WHERE p_character_ids IS NOT NULL
    AND pg_catalog.cardinality(p_character_ids) BETWEEN 1 AND 10;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_character_schedules(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_character_schedules(uuid[]) TO anon, authenticated;

-- The city map needs exactly one schedule per character: the variant valid now in Taiwan,
-- already resolved for weekday/holiday, primary/alternative, and rain fallback.
-- Preserve the existing 16-column RPC return contract; current map UI consumes its first eight fields.
CREATE OR REPLACE FUNCTION public.get_encounter_character_schedules(p_character_ids uuid[])
RETURNS TABLE (
  character_id uuid,
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
  priority smallint,
  encounter_greeting text,
  is_outdoor boolean,
  rain_fallback_location_key text,
  rain_fallback_activity text,
  rain_fallback_greeting text,
  source_type text,
  variant_key text,
  variant_weight smallint
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    c.id,
    resolved.weekday,
    resolved.day_type,
    resolved.start_time,
    resolved.end_time,
    resolved.location_key,
    resolved.activity,
    resolved.priority,
    resolved.encounter_greeting,
    resolved.is_outdoor,
    resolved.rain_fallback_location_key,
    resolved.rain_fallback_activity,
    resolved.rain_fallback_greeting,
    resolved.source_type,
    resolved.variant_key,
    resolved.variant_weight
  FROM (
    SELECT DISTINCT requested.character_id
    FROM pg_catalog.unnest(p_character_ids) AS requested(character_id)
    WHERE requested.character_id IS NOT NULL
  ) AS requested
  JOIN public.characters c ON c.id = requested.character_id
  CROSS JOIN LATERAL public.resolve_encounter_character_schedule(
    c.id,
    (SELECT auth.uid()),
    NULL,
    pg_catalog.now()
  ) AS resolved
  WHERE p_character_ids IS NOT NULL
    AND pg_catalog.cardinality(p_character_ids) BETWEEN 1 AND 10
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL
  ORDER BY c.id, resolved.priority DESC, resolved.start_time;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_character_schedules(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_character_schedules(uuid[]) TO anon, authenticated;

COMMENT ON FUNCTION public.get_encounter_character_schedules(uuid[]) IS
  'Returns current Taiwan-time schedules for supplied public characters. Rain fallback is decided once per schedule slot and persisted until that slot ends, so later weather changes never move a character mid-slot. Preserves the original 16-column RPC contract and 10-ID batch limit.';

CREATE OR REPLACE FUNCTION public.save_character_schedules(
  p_character_id uuid,
  p_schedules jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_count integer;
BEGIN
  IF v_uid IS NULL OR public.account_is_active() IS NOT TRUE THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_character_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.characters c
    WHERE c.id = p_character_id AND c.author_id = v_uid AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Character not found or not owned by caller' USING ERRCODE = '42501';
  END IF;

  IF p_schedules IS NULL OR jsonb_typeof(p_schedules) <> 'array' THEN
    RAISE EXCEPTION 'Schedules must be a JSON array' USING ERRCODE = '22023';
  END IF;

  v_count := jsonb_array_length(p_schedules);
  IF v_count > 50 THEN
    RAISE EXCEPTION 'At most 50 schedule rows are allowed' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_schedules) AS e(value)
    WHERE jsonb_typeof(e.value) <> 'object'
      OR (e.value ? 'weekday' AND e.value->'weekday' <> 'null'::jsonb
          AND (jsonb_typeof(e.value->'weekday') <> 'number'
               OR (e.value->>'weekday') !~ '^[0-6]$'))
      OR COALESCE(e.value->>'day_type', 'any') NOT IN ('any', 'weekday', 'weekend', 'holiday')
      OR COALESCE(e.value->>'start_time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      OR COALESCE(e.value->>'end_time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      OR COALESCE(e.value->>'start_time', '') = COALESCE(e.value->>'end_time', '')
      OR COALESCE(e.value->>'location_key', '') !~ '^[A-Za-z0-9_-]{1,80}$'
      OR char_length(COALESCE(e.value->>'activity', '')) NOT BETWEEN 1 AND 300
  ) THEN
    RAISE EXCEPTION 'One or more schedule rows are invalid' USING ERRCODE = '22023';
  END IF;

  -- Preserve AI-published and legacy rows. This RPC replaces only explicit
  -- author-managed rows; manual rows win resolver priority over AI rows.
  DELETE FROM public.character_schedules
  WHERE character_id = p_character_id AND source_type = 'manual';

  INSERT INTO public.character_schedules (
    character_id, weekday, day_type, start_time, end_time,
    location_key, activity, priority, is_active, source_type,
    variant_key, variant_weight, encounter_greeting, is_outdoor,
    rain_fallback_location_key, rain_fallback_activity, rain_fallback_greeting
  )
  SELECT
    p_character_id, x.weekday, COALESCE(x.day_type, 'any'),
    x.start_time::time, x.end_time::time, x.location_key, x.activity,
    100, true, 'manual', 'primary', 100, '', false, NULL, NULL, NULL
  FROM jsonb_to_recordset(p_schedules) AS x(
    weekday smallint, day_type text, start_time text, end_time text,
    location_key text, activity text
  );

  -- Re-enqueue only through the author-facing RPC; AI publication writes are not retriggered.
  PERFORM public.enqueue_encounter_schedule_generation_internal(p_character_id);
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.save_character_schedules(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_character_schedules(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_encounter_city_weather()
RETURNS TABLE (
  weather_text text,
  temperature_c numeric,
  is_raining boolean,
  precipitation_1h_mm numeric,
  observed_at timestamptz,
  weather_source text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $encounter_city_weather$
  WITH latest AS (
    SELECT w.*
    FROM public.encounter_city_weather w
    WHERE w.city_key = 'taipei'
    ORDER BY w.fetched_at DESC
    LIMIT 1
  )
  SELECT
    COALESCE(latest.weather_text, '多雲'),
    COALESCE(latest.temperature_c, 24::numeric),
    COALESCE(latest.is_raining, false),
    latest.precipitation_1h_mm,
    COALESCE(latest.observed_at, latest.fetched_at),
    COALESCE(latest.source, 'poyozz_fallback')
  FROM (SELECT 1) AS seed
  LEFT JOIN latest ON true;
$encounter_city_weather$;

REVOKE ALL ON FUNCTION public.get_encounter_city_weather() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_city_weather() TO anon, authenticated, service_role;

COMMENT ON TABLE public.encounter_city_weather IS
  'One cached fictional Taipei weather state generated every six hours; no external weather API, forecast, or historical baseline dependency.';

CREATE OR REPLACE FUNCTION public.get_encounter_scene_registry()
RETURNS TABLE (
  location_key text,
  display_name text,
  icon text,
  marker_x integer,
  marker_y integer,
  heading text,
  description text,
  event_label text,
  event_title text,
  event_description text,
  character_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $encounter_scene_registry$
  SELECT
    r.location_key,
    r.display_name,
    r.icon,
    r.marker_x,
    r.marker_y,
    r.heading,
    r.description,
    r.event_label,
    r.event_title,
    r.event_description,
    pg_catalog.count(DISTINCT c.id) AS character_count
  FROM public.encounter_scene_registry r
  JOIN public.character_schedules s
    ON s.location_key = r.location_key
   AND s.is_active IS TRUE
   AND s.special_event_key IS NULL
  JOIN public.characters c ON c.id = s.character_id
  WHERE r.is_dynamic IS TRUE
    AND r.is_active IS TRUE
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL
    AND (
      c.is_nsfw IS NOT TRUE
      OR ((SELECT auth.uid()) IS NOT NULL AND private.current_user_is_adult())
    )
  GROUP BY
    r.location_key, r.display_name, r.icon, r.marker_x, r.marker_y,
    r.heading, r.description, r.event_label, r.event_title,
    r.event_description, r.minimum_character_count, r.display_order
  HAVING pg_catalog.count(DISTINCT c.id) >= r.minimum_character_count
  ORDER BY r.display_order, r.location_key
  LIMIT 3;
$encounter_scene_registry$;

REVOKE ALL ON FUNCTION public.get_encounter_scene_registry() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_scene_registry() TO anon, authenticated;

COMMENT ON FUNCTION public.get_encounter_scene_registry() IS
  'Returns only allowlisted dynamic city-scene markers whose published schedules are shared by the configured minimum number of eligible public characters. Coordinates and scene metadata come only from the server-owned registry.';

CREATE OR REPLACE FUNCTION public.schedule_encounter_worker(
  p_worker text,
  p_enabled boolean DEFAULT false
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $encounter_worker_scheduler$
DECLARE
  v_job_name text;
  v_cron_schedule text;
  v_endpoint text;
  v_timeout integer;
  v_project_url text;
  v_service_key text;
  v_job_id bigint;
  v_command text;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  CASE p_worker
    WHEN 'schedule_organizer' THEN
      v_job_name := 'poyozz-encounter-schedule-organizer';
      v_cron_schedule := '*/15 * * * *';
      v_endpoint := 'encounter-schedule-organizer';
      v_timeout := 120000;
    WHEN 'weather_sync' THEN
      v_job_name := 'poyozz-encounter-weather-sync';
      v_cron_schedule := '0 */6 * * *';
      v_endpoint := 'encounter-weather-sync';
      v_timeout := 30000;
    WHEN 'taiwan_calendar_sync' THEN
      v_job_name := 'poyozz-encounter-taiwan-calendar-sync';
      v_cron_schedule := '0 19 1 * *';
      v_endpoint := 'encounter-taiwan-calendar-sync';
      v_timeout := 30000;
    ELSE
      RAISE EXCEPTION 'encounter_worker_not_allowed' USING ERRCODE = '22023';
  END CASE;

  IF to_regclass('cron.job') IS NULL
     OR to_regclass('vault.decrypted_secrets') IS NULL
     OR to_regprocedure('cron.schedule(text,text,text)') IS NULL
     OR to_regprocedure('cron.unschedule(bigint)') IS NULL
     OR to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') IS NULL THEN
    RETURN 'scheduler_extensions_missing';
  END IF;

  IF p_enabled IS NOT TRUE THEN
    FOR v_job_id IN
      SELECT jobid FROM cron.job WHERE jobname = v_job_name
    LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;
    RETURN 'disabled:' || v_job_name;
  END IF;

  SELECT decrypted_secret INTO v_project_url
  FROM vault.decrypted_secrets WHERE name = 'poyozz_supabase_url' LIMIT 1;
  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'poyozz_service_role_key' LIMIT 1;

  IF COALESCE(v_project_url, '') !~ '^https://[a-zA-Z0-9-]+[.]supabase[.]co/?$'
     OR COALESCE(v_service_key, '') = '' THEN
    RETURN 'vault_secrets_missing';
  END IF;

  v_command := pg_catalog.format(
    $encounter_cron_command$
      SELECT net.http_post(
        url := regexp_replace(
          (SELECT decrypted_secret FROM vault.decrypted_secrets
           WHERE name = 'poyozz_supabase_url' LIMIT 1),
          '/+$', ''
        ) || '/functions/v1/%s',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || (
            SELECT decrypted_secret FROM vault.decrypted_secrets
            WHERE name = 'poyozz_service_role_key' LIMIT 1
          ),
          'Content-Type', 'application/json'
        ),
        body := '{"mode":"scheduled"}'::jsonb,
        timeout_milliseconds := %s
      );
    $encounter_cron_command$,
    v_endpoint,
    v_timeout
  );

  FOR v_job_id IN
    SELECT jobid FROM cron.job WHERE jobname = v_job_name
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;

  PERFORM cron.schedule(v_job_name, v_cron_schedule, v_command);
  RETURN 'scheduled:' || v_job_name || ':' || v_cron_schedule;
END;
$encounter_worker_scheduler$;

REVOKE ALL ON FUNCTION public.schedule_encounter_worker(text, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_worker(text, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.schedule_encounter_schedule_organizer(
  p_enabled boolean DEFAULT false
)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $schedule_organizer_wrapper$
  SELECT public.schedule_encounter_worker('schedule_organizer', p_enabled);
$schedule_organizer_wrapper$;

CREATE OR REPLACE FUNCTION public.schedule_encounter_weather_sync(
  p_enabled boolean DEFAULT false
)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $weather_sync_wrapper$
  SELECT public.schedule_encounter_worker('weather_sync', p_enabled);
$weather_sync_wrapper$;

CREATE OR REPLACE FUNCTION public.schedule_encounter_taiwan_calendar_sync(
  p_enabled boolean DEFAULT false
)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $calendar_sync_wrapper$
  SELECT public.schedule_encounter_worker('taiwan_calendar_sync', p_enabled);
$calendar_sync_wrapper$;

REVOKE ALL ON FUNCTION public.schedule_encounter_schedule_organizer(boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.schedule_encounter_weather_sync(boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.schedule_encounter_taiwan_calendar_sync(boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_schedule_organizer(boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_weather_sync(boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_taiwan_calendar_sync(boolean) TO service_role;

COMMENT ON TABLE public.encounter_schedule_generation_jobs IS
  'Service-role-only unique-per-character queue. Enqueue triggers run on author schedule-description changes and public eligibility changes. Threshold counts distinct public approved characters; a 23h45m fallback trigger plus 15-minute cron interval keeps the nominal maximum under 24 hours before global rate limits.';
COMMENT ON TABLE public.encounter_schedule_batch_runs IS
  'Global schedule AI batch ledger enforcing six-hour cooldown and four batches per Taipei calendar day.';
COMMENT ON TABLE public.encounter_scene_registry IS
  'Server-owned allowlist for city-map scene markers. V1 exposes the shared shopping-street scene only after at least two eligible public characters use it; AI never supplies coordinates.';
COMMENT ON TABLE public.taiwan_calendar_days IS
  'Taiwan government office calendar dates, including official holidays and make-up workdays. Synced from the published government calendar dataset.';
COMMENT ON TABLE public.encounter_city_weather IS
  'One cached fictional Taipei weather state generated every six hours; no external weather API, forecast, or historical baseline dependency.';
COMMENT ON FUNCTION public.schedule_encounter_worker(text, boolean) IS
  'Allowlisted opt-in scheduler for Encounter background workers. No jobs are activated by migration.';
COMMENT ON FUNCTION public.schedule_encounter_schedule_organizer(boolean) IS
  'Opt-in 15-minute schedule organizer cron wrapper; manual test trigger is separate.';
COMMENT ON FUNCTION public.schedule_encounter_weather_sync(boolean) IS
  'Opt-in six-hour deterministic seasonal Taipei weather simulation; no external weather API or historical baseline.';
COMMENT ON FUNCTION public.schedule_encounter_taiwan_calendar_sync(boolean) IS
  'Opt-in monthly Taiwan official calendar refresh wrapper. Runs at 03:00 Asia/Taipei on the first day of each month.';

COMMIT;
),
  greeting_pools jsonb NOT NULL CHECK (
    jsonb_typeof(greeting_pools) = 'object'
    AND pg_column_size(greeting_pools) <= 24000
  ),
  generated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

ALTER TABLE public.encounter_character_greeting_pools ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.encounter_character_greeting_pools FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_character_greeting_pools TO service_role;
COMMENT ON TABLE public.encounter_character_greeting_pools IS
  'Private trusted-generated opening greeting pools per character and relationship stage. Player-specific selection is persisted in the created Encounter session.';

CREATE TABLE IF NOT EXISTS public.encounter_schedule_generation_jobs (
  character_id uuid PRIMARY KEY REFERENCES public.characters(id) ON DELETE CASCADE,
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  source_hash text NOT NULL,
  last_completed_source_hash text,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'failed', 'needs_reconciliation', 'completed', 'cancelled')),
  queued_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  available_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  attempt_count smallint NOT NULL DEFAULT 0 CHECK (attempt_count BETWEEN 0 AND 100),
  lease_token uuid,
  lease_expires_at timestamptz,
  lease_generation bigint NOT NULL DEFAULT 0,
  last_error_code text,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

CREATE INDEX IF NOT EXISTS encounter_schedule_jobs_ready_idx
  ON public.encounter_schedule_generation_jobs (status, available_at, queued_at);

CREATE TABLE IF NOT EXISTS public.encounter_schedule_batch_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lease_token uuid NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'processing'
    CHECK (status IN ('processing', 'completed', 'failed', 'needs_reconciliation', 'cancelled')),
  character_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  actor_user_id uuid,
  is_manual boolean NOT NULL DEFAULT false,
  started_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  completed_at timestamptz,
  failure_code text,
  published_character_count integer NOT NULL DEFAULT 0,
  unplaced_character_count integer NOT NULL DEFAULT 0,
  skipped_character_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

CREATE INDEX IF NOT EXISTS encounter_schedule_batch_runs_started_idx
  ON public.encounter_schedule_batch_runs (started_at DESC);

CREATE TABLE IF NOT EXISTS public.encounter_schedule_generation_usage (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.encounter_schedule_batch_runs(id) ON DELETE CASCADE,
  requested_model text NOT NULL,
  provider text NOT NULL,
  status text NOT NULL,
  usage jsonb NOT NULL DEFAULT '{}'::jsonb,
  gateway_request_id text,
  failure_code text,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

ALTER TABLE public.character_schedules
  ADD COLUMN IF NOT EXISTS source_type text NOT NULL DEFAULT 'legacy',
  ADD COLUMN IF NOT EXISTS variant_key text NOT NULL DEFAULT 'primary',
  ADD COLUMN IF NOT EXISTS variant_weight smallint NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS special_event_key text,
  ADD COLUMN IF NOT EXISTS encounter_greeting text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS is_outdoor boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS rain_fallback_location_key text,
  ADD COLUMN IF NOT EXISTS rain_fallback_activity text,
  ADD COLUMN IF NOT EXISTS rain_fallback_greeting text,
  ADD COLUMN IF NOT EXISTS batch_id uuid REFERENCES public.encounter_schedule_batch_runs(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS source_hash text;

ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_day_type_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_day_type_check
  CHECK (day_type IN ('any', 'weekday', 'weekend', 'holiday'));

ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_source_type_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_source_type_check
  CHECK (source_type IN ('legacy', 'manual', 'ai'));
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_variant_key_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_variant_key_check
  CHECK (variant_key IN ('primary', 'alternative', 'special'));
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_special_event_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_special_event_check
  CHECK (
    (variant_key = 'special'
      AND special_event_key IN ('taiwan_public_holiday', 'lunar_new_year', 'valentines_day', 'christmas')
      AND day_type = 'any'
      AND variant_weight = 100)
    OR (variant_key IN ('primary', 'alternative') AND special_event_key IS NULL)
  );
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_variant_weight_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_variant_weight_check
  CHECK (variant_weight BETWEEN 0 AND 100);
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_encounter_greeting_length_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_encounter_greeting_length_check
  CHECK (encounter_greeting = '' OR char_length(encounter_greeting) BETWEEN 150 AND 300);
ALTER TABLE public.character_schedules
  DROP CONSTRAINT IF EXISTS character_schedules_rain_fallback_consistency_check;
ALTER TABLE public.character_schedules
  ADD CONSTRAINT character_schedules_rain_fallback_consistency_check
  CHECK (
    (is_outdoor IS TRUE
      AND rain_fallback_location_key IS NOT NULL
      AND rain_fallback_activity IS NOT NULL
      AND rain_fallback_greeting IS NOT NULL
      AND char_length(rain_fallback_greeting) BETWEEN 150 AND 300)
    OR
    (is_outdoor IS FALSE
      AND rain_fallback_location_key IS NULL
      AND rain_fallback_activity IS NULL
      AND rain_fallback_greeting IS NULL)
  );

CREATE INDEX IF NOT EXISTS character_schedules_current_variant_idx
  ON public.character_schedules (character_id, is_active, day_type, variant_key, start_time)
  WHERE is_active IS TRUE;

CREATE INDEX IF NOT EXISTS character_schedules_special_event_idx
  ON public.character_schedules (character_id, special_event_key, start_time)
  WHERE is_active IS TRUE AND special_event_key IS NOT NULL;

-- Freeze the weather fallback selected for a specific occurrence of a schedule.
-- A weather change during the slot must not move an active encounter mid-scene.
CREATE TABLE IF NOT EXISTS public.encounter_schedule_weather_decisions (
  schedule_id uuid NOT NULL REFERENCES public.character_schedules(id) ON DELETE CASCADE,
  scheduled_start_at timestamptz NOT NULL,
  scheduled_end_at timestamptz NOT NULL,
  location_key text NOT NULL,
  activity text NOT NULL,
  encounter_greeting text NOT NULL DEFAULT '',
  is_outdoor boolean NOT NULL DEFAULT false,
  decided_weather_text text NOT NULL DEFAULT '多雲',
  decided_is_raining boolean NOT NULL DEFAULT false,
  decided_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (schedule_id, scheduled_start_at),
  CHECK (scheduled_end_at > scheduled_start_at)
);
CREATE INDEX IF NOT EXISTS encounter_schedule_weather_decisions_end_idx
  ON public.encounter_schedule_weather_decisions (scheduled_end_at);
REVOKE ALL ON TABLE public.encounter_schedule_weather_decisions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.encounter_schedule_weather_decisions TO service_role;

CREATE TABLE IF NOT EXISTS public.taiwan_calendar_days (
  calendar_date date PRIMARY KEY,
  day_type text NOT NULL CHECK (day_type IN ('holiday', 'workday')),
  holiday_name text,
  source text NOT NULL DEFAULT 'government_calendar',
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

ALTER TABLE public.taiwan_calendar_days
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT pg_catalog.now();

-- Older sync versions copied holidaycategory (e.g. "週末假期") into holiday_name.
-- Clear those generic labels so weekends never trigger special-event schedules.
UPDATE public.taiwan_calendar_days
SET holiday_name = NULL,
    updated_at = pg_catalog.now()
WHERE pg_catalog.btrim(COALESCE(holiday_name, '')) ~
  '^(週末假期|周末假期|週末假期等|周末假期等|星期六|星期日|週六|週日|放假|放假日|休假日|假日|例假日)$';

CREATE TABLE IF NOT EXISTS public.encounter_city_weather (
  city_key text PRIMARY KEY CHECK (city_key = 'taipei'),
  weather_text text NOT NULL DEFAULT '天氣資料待更新',
  temperature_c numeric(4,1),
  precipitation_1h_mm numeric(6,1),
  is_raining boolean NOT NULL DEFAULT false,
  observed_at timestamptz,
  fetched_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  source text NOT NULL DEFAULT 'poyozz_fictional_seasonal',
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

ALTER TABLE public.encounter_city_weather ALTER COLUMN source SET DEFAULT 'poyozz_fictional_seasonal';

UPDATE public.encounter_city_weather
SET weather_text = '多雲',
    temperature_c = 24,
    precipitation_1h_mm = NULL,
    is_raining = false,
    observed_at = pg_catalog.now(),
    fetched_at = pg_catalog.now(),
    source = 'poyozz_fallback',
    updated_at = pg_catalog.now()
WHERE source IS DISTINCT FROM 'poyozz_fictional_seasonal'
  AND source IS DISTINCT FROM 'poyozz_fallback';



CREATE INDEX IF NOT EXISTS encounter_city_weather_fetched_idx
  ON public.encounter_city_weather (fetched_at DESC);

CREATE TABLE IF NOT EXISTS public.encounter_scene_registry (
  location_key text PRIMARY KEY,
  display_name text NOT NULL,
  icon text NOT NULL,
  marker_x integer NOT NULL,
  marker_y integer NOT NULL,
  heading text NOT NULL,
  description text NOT NULL,
  event_label text NOT NULL DEFAULT '場景亮點',
  event_title text NOT NULL,
  event_description text NOT NULL,
  is_dynamic boolean NOT NULL DEFAULT false,
  minimum_character_count smallint NOT NULL DEFAULT 1 CHECK (minimum_character_count BETWEEN 1 AND 100),
  display_order smallint NOT NULL DEFAULT 100,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CHECK (marker_x BETWEEN 40 AND 1622),
  CHECK (marker_y BETWEEN 40 AND 892),
  CHECK (is_dynamic IS FALSE OR location_key IN ('shopping-street'))
);

-- V1 allows one controlled dynamic scene type. The AI can propose this key,
-- but never supplies marker coordinates or arbitrary display metadata.
INSERT INTO public.encounter_scene_registry (
  location_key, display_name, icon, marker_x, marker_y,
  heading, description, event_label, event_title, event_description,
  is_dynamic, minimum_character_count, display_order, is_active
) VALUES (
  'shopping-street', '商店街', '🛍️', 1230, 620,
  '沿著街道慢慢逛，遇見城市日常',
  '街邊店舖、櫥窗與行人交織成熱鬧的生活場景。角色可以在不同店家之間移動，也能在街角停下來與熟悉的人碰面。',
  '場景亮點', '街角的偶遇',
  '適合逛街、採買、散步、朋友同行或在店家之間自然相遇。',
  true, 2, 10, true
)
ON CONFLICT (location_key) DO UPDATE
SET display_name = EXCLUDED.display_name,
    icon = EXCLUDED.icon,
    marker_x = EXCLUDED.marker_x,
    marker_y = EXCLUDED.marker_y,
    heading = EXCLUDED.heading,
    description = EXCLUDED.description,
    event_label = EXCLUDED.event_label,
    event_title = EXCLUDED.event_title,
    event_description = EXCLUDED.event_description,
    is_dynamic = EXCLUDED.is_dynamic,
    minimum_character_count = EXCLUDED.minimum_character_count,
    display_order = EXCLUDED.display_order,
    is_active = EXCLUDED.is_active,
    updated_at = pg_catalog.clock_timestamp();

CREATE TABLE IF NOT EXISTS public.encounter_scene_backgrounds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  location_key text NOT NULL DEFAULT '*',
  display_name text NOT NULL,
  asset_path text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order smallint NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CHECK (location_key = '*' OR location_key IN (
    'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
    'department-store', 'bookstore', 'cafe', 'park', 'shopping-street'
  )),
  CHECK (asset_path ~ '^([.]/|/)[A-Za-z0-9_./-]+$')
);

INSERT INTO public.encounter_scene_backgrounds (location_key, display_name, asset_path, is_active, sort_order)
SELECT '*', '城市預設場景', './encounter-default-scene.webp', true, 0
WHERE NOT EXISTS (
  SELECT 1 FROM public.encounter_scene_backgrounds
  WHERE location_key = '*' AND asset_path = './encounter-default-scene.webp'
);

CREATE TABLE IF NOT EXISTS public.encounter_turn_visuals (
  message_id uuid PRIMARY KEY REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  session_id uuid NOT NULL REFERENCES public.chat_sessions(id) ON DELETE CASCADE,
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
  illustration_id uuid REFERENCES public.character_illustrations(id) ON DELETE SET NULL,
  scene_background_id uuid REFERENCES public.encounter_scene_backgrounds(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

CREATE INDEX IF NOT EXISTS encounter_turn_visuals_session_idx
  ON public.encounter_turn_visuals (session_id, created_at DESC);
CREATE INDEX IF NOT EXISTS encounter_turn_visuals_character_idx
  ON public.encounter_turn_visuals (character_id, created_at DESC);

ALTER TABLE public.encounter_schedule_generation_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_schedule_batch_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_schedule_generation_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taiwan_calendar_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_city_weather ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_scene_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_scene_backgrounds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_turn_visuals ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.encounter_schedule_generation_jobs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_schedule_batch_runs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_schedule_generation_usage FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.taiwan_calendar_days FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_city_weather FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_scene_registry FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_scene_backgrounds FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_turn_visuals FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_schedule_generation_jobs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_schedule_batch_runs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_schedule_generation_usage TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_city_weather TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_scene_backgrounds TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_turn_visuals TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.taiwan_calendar_days TO service_role;


CREATE OR REPLACE FUNCTION public.encounter_schedule_source_payload(p_character_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'schedule_schema_version', 'poyozz-encounter-schedule-v3-relationship-greetings-2026-11-17',
    'character_id', c.id::text,
    'author_id', c.author_id::text,
    'visibility', c.visibility,
    'review_status', c.review_status,
    'rights_confirmed', c.rights_confirmed,
    'deleted_at', c.deleted_at,
    'name', c.name,
    'title', COALESCE(c.title, ''),
    'intro', COALESCE(c.intro, ''),
    'race', COALESCE(c.race, ''),
    'style', COALESCE(c.style, ''),
    'gender', COALESCE(c.gender, ''),
    'age', COALESCE(c.age::text, ''),
    'tags', COALESCE(pg_catalog.to_jsonb(c.tags), '[]'::jsonb),
    'occupation', COALESCE(c.personality_profile ->> 'occupation', ''),
    'world_era', pg_catalog.concat_ws(' ', c.intro, c.race, c.style),
    'modern_setting_compatible',
      pg_catalog.concat_ws(' ', c.intro, COALESCE(d.description, ''), p.private_info, c.personality_profile::text)
      ~ '(現代世界|現代背景|現代都市|現代社會|現代生活|當代)',
    'time_travel_explicit',
      pg_catalog.concat_ws(' ', c.intro, COALESCE(d.description, ''), p.private_info, c.personality_profile::text)
      ~ '(穿越到現代|穿越至現代|來到現代|時空旅行到現代|穿越現代)',
    'schedule_description', COALESCE(d.description, ''),
    'existing_author_schedules', COALESCE((
      SELECT pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'weekday', s.weekday,
          'day_type', s.day_type,
          'start_time', pg_catalog.to_char(s.start_time, 'HH24:MI'),
          'end_time', pg_catalog.to_char(s.end_time, 'HH24:MI'),
          'location_key', s.location_key,
          'activity', s.activity
        )
        ORDER BY s.priority DESC, s.start_time
      )
      FROM public.character_schedules s
      WHERE s.character_id = c.id
        AND s.source_type = 'manual'
        AND s.is_active IS TRUE
    ), '[]'::jsonb),
    'private_info', COALESCE(p.private_info, ''),
    'personality_profile', COALESCE(c.personality_profile, '{}'::jsonb)
  )
  FROM public.characters c
  LEFT JOIN public.character_schedule_descriptions d
    ON d.character_id = c.id AND d.author_id = c.author_id
  LEFT JOIN public.character_private_info p
    ON p.character_id = c.id AND p.author_id = c.author_id
  WHERE c.id = p_character_id
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL
$$;

REVOKE ALL ON FUNCTION public.encounter_schedule_source_payload(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.encounter_schedule_source_payload(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_encounter_schedule_generation_internal(p_character_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source jsonb;
  v_hash text;
  v_status text;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  v_source := public.encounter_schedule_source_payload(p_character_id);

  IF v_source IS NULL THEN
    UPDATE public.encounter_schedule_generation_jobs
    SET status = 'cancelled', lease_token = NULL, lease_expires_at = NULL,
        last_error_code = 'character_not_public_or_schedule_missing',
        updated_at = v_now
    WHERE character_id = p_character_id;

    UPDATE public.character_schedules
    SET is_active = false, updated_at = v_now
    WHERE character_id = p_character_id AND source_type = 'ai' AND is_active IS TRUE;

    RETURN pg_catalog.jsonb_build_object('status', 'not_eligible');
  END IF;

  v_hash := pg_catalog.md5(v_source::text);
  INSERT INTO public.encounter_schedule_generation_jobs (
    character_id, author_id, source_hash, status, queued_at, available_at,
    attempt_count, lease_token, lease_expires_at, lease_generation,
    last_error_code, completed_at, updated_at
  ) VALUES (
    p_character_id, (v_source->>'author_id')::uuid, v_hash, 'pending',
    v_now, v_now, 0, NULL, NULL, 1, NULL, NULL, v_now
  )
  ON CONFLICT (character_id) DO UPDATE
  SET author_id = EXCLUDED.author_id,
      source_hash = EXCLUDED.source_hash,
      status = 'pending',
      queued_at = CASE
        WHEN public.encounter_schedule_generation_jobs.status IN
          ('pending', 'processing', 'failed', 'needs_reconciliation')
          THEN public.encounter_schedule_generation_jobs.queued_at
        ELSE v_now
      END,
      available_at = v_now,
      attempt_count = 0,
      lease_token = NULL,
      lease_expires_at = NULL,
      lease_generation = public.encounter_schedule_generation_jobs.lease_generation + 1,
      last_error_code = NULL,
      completed_at = NULL,
      updated_at = v_now
  WHERE public.encounter_schedule_generation_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash
     OR public.encounter_schedule_generation_jobs.status = 'cancelled'
  RETURNING status INTO v_status;

  IF v_status IS NULL THEN
    SELECT status INTO v_status
    FROM public.encounter_schedule_generation_jobs
    WHERE character_id = p_character_id;
  END IF;

  RETURN pg_catalog.jsonb_build_object('status', COALESCE(v_status, 'pending'));
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_encounter_schedule_generation_internal(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.enqueue_encounter_schedule_generation(p_character_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR public.account_is_active() IS NOT TRUE THEN
    RAISE EXCEPTION 'active_authentication_required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.characters c
    WHERE c.id = p_character_id AND c.author_id = v_uid AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'character_not_found_or_not_owned' USING ERRCODE = '42501';
  END IF;

  RETURN public.enqueue_encounter_schedule_generation_internal(p_character_id);
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_encounter_schedule_generation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enqueue_encounter_schedule_generation(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.on_encounter_schedule_description_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_character_id uuid;
BEGIN
  v_character_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.character_id ELSE NEW.character_id END;
  PERFORM public.enqueue_encounter_schedule_generation_internal(v_character_id);
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.on_encounter_schedule_description_changed()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS character_schedule_descriptions_enqueue_ai ON public.character_schedule_descriptions;
CREATE TRIGGER character_schedule_descriptions_enqueue_ai
AFTER INSERT OR UPDATE OF description, author_id OR DELETE
ON public.character_schedule_descriptions
FOR EACH ROW EXECUTE FUNCTION public.on_encounter_schedule_description_changed();

CREATE OR REPLACE FUNCTION public.on_encounter_character_visibility_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.enqueue_encounter_schedule_generation_internal(NEW.id);
    RETURN NEW;
  END IF;

  IF OLD.author_id IS DISTINCT FROM NEW.author_id
     OR OLD.name IS DISTINCT FROM NEW.name
     OR OLD.title IS DISTINCT FROM NEW.title
     OR OLD.intro IS DISTINCT FROM NEW.intro
     OR OLD.race IS DISTINCT FROM NEW.race
     OR OLD.style IS DISTINCT FROM NEW.style
     OR OLD.gender IS DISTINCT FROM NEW.gender
     OR OLD.age IS DISTINCT FROM NEW.age
     OR OLD.tags IS DISTINCT FROM NEW.tags
     OR OLD.personality_profile IS DISTINCT FROM NEW.personality_profile
     OR OLD.visibility IS DISTINCT FROM NEW.visibility
     OR OLD.review_status IS DISTINCT FROM NEW.review_status
     OR OLD.rights_confirmed IS DISTINCT FROM NEW.rights_confirmed
     OR OLD.deleted_at IS DISTINCT FROM NEW.deleted_at THEN
    PERFORM public.enqueue_encounter_schedule_generation_internal(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.on_encounter_character_visibility_changed()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS characters_enqueue_encounter_schedule_ai ON public.characters;
CREATE TRIGGER characters_enqueue_encounter_schedule_ai
AFTER INSERT OR UPDATE OF author_id, name, title, intro, race, style, gender, age, tags,
  personality_profile, visibility, review_status, rights_confirmed, deleted_at
ON public.characters
FOR EACH ROW EXECUTE FUNCTION public.on_encounter_character_visibility_changed();

CREATE OR REPLACE FUNCTION public.on_encounter_character_private_info_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_character_id uuid;
BEGIN
  v_character_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.character_id ELSE NEW.character_id END;
  PERFORM public.enqueue_encounter_schedule_generation_internal(v_character_id);
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.on_encounter_character_private_info_changed()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS character_private_info_enqueue_encounter_schedule_ai ON public.character_private_info;
CREATE TRIGGER character_private_info_enqueue_encounter_schedule_ai
AFTER INSERT OR UPDATE OF author_id, private_info OR DELETE
ON public.character_private_info
FOR EACH ROW EXECUTE FUNCTION public.on_encounter_character_private_info_changed();

CREATE OR REPLACE FUNCTION public.claim_encounter_schedule_batch(
  p_limit integer DEFAULT 10,
  p_force boolean DEFAULT false,
  p_actor_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 10);
  v_pending_count integer := 0;
  v_oldest timestamptz;
  v_last_started timestamptz;
  v_day_start timestamptz;
  v_daily_count integer := 0;
  v_lease uuid := gen_random_uuid();
  v_batch uuid;
  v_ids uuid[];
  v_characters jsonb;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('poyozz_encounter_schedule_batch')::bigint);

  UPDATE public.encounter_schedule_generation_jobs
  SET status = 'needs_reconciliation',
      available_at = v_now + interval '6 hours',
      lease_token = NULL,
      lease_expires_at = NULL,
      last_error_code = 'worker_lease_expired',
      updated_at = v_now
  WHERE status = 'processing'
    AND lease_expires_at IS NOT NULL
    AND lease_expires_at < v_now;

  UPDATE public.encounter_schedule_batch_runs
  SET status = 'needs_reconciliation',
      failure_code = COALESCE(failure_code, 'worker_lease_expired'),
      updated_at = v_now
  WHERE status = 'processing'
    AND started_at < v_now - interval '20 minutes';

  SELECT COUNT(DISTINCT j.character_id), MIN(j.queued_at)
  INTO v_pending_count, v_oldest
  FROM public.encounter_schedule_generation_jobs j
  JOIN public.characters c ON c.id = j.character_id
  LEFT JOIN public.character_schedule_descriptions d
    ON d.character_id = j.character_id AND d.author_id = j.author_id
  WHERE j.status IN ('pending', 'failed', 'needs_reconciliation')
    AND (p_force IS TRUE OR j.available_at <= v_now)
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL;

  IF p_force IS NOT TRUE THEN
    IF v_pending_count < 10
       AND (v_oldest IS NULL OR v_oldest > v_now - interval '23 hours 45 minutes') THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'waiting_threshold',
        'pending_character_count', v_pending_count,
        'oldest_queued_at', v_oldest
      );
    END IF;

    v_day_start := (
      pg_catalog.date_trunc('day', v_now AT TIME ZONE 'Asia/Taipei')
      AT TIME ZONE 'Asia/Taipei'
    );
    SELECT COUNT(*) INTO v_daily_count
    FROM public.encounter_schedule_batch_runs b
    WHERE b.started_at >= v_day_start;

    IF v_daily_count >= 4 THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'daily_limit',
        'pending_character_count', v_pending_count,
        'next_eligible_at', v_day_start + interval '1 day'
      );
    END IF;

    SELECT MAX(b.started_at) INTO v_last_started
    FROM public.encounter_schedule_batch_runs b;
    IF v_last_started IS NOT NULL AND v_last_started > v_now - interval '6 hours' THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'cooldown',
        'pending_character_count', v_pending_count,
        'next_eligible_at', v_last_started + interval '6 hours'
      );
    END IF;
  END IF;

  WITH candidates AS (
    SELECT j.character_id
    FROM public.encounter_schedule_generation_jobs j
    JOIN public.characters c ON c.id = j.character_id
    LEFT JOIN public.character_schedule_descriptions d
      ON d.character_id = j.character_id AND d.author_id = j.author_id
    WHERE j.status IN ('pending', 'failed', 'needs_reconciliation')
      AND (p_force IS TRUE OR j.available_at <= v_now)
      AND (p_force IS TRUE OR j.attempt_count < 3 OR j.status = 'needs_reconciliation')
      AND c.visibility = 'public'
      AND c.review_status = 'approved'
      AND c.rights_confirmed IS TRUE
      AND c.deleted_at IS NULL
    ORDER BY j.queued_at, j.character_id
    LIMIT v_limit
    FOR UPDATE OF j SKIP LOCKED
  ),
  claimed AS (
    UPDATE public.encounter_schedule_generation_jobs j
    SET status = 'processing',
        lease_token = v_lease,
        lease_expires_at = v_now + interval '20 minutes',
        lease_generation = j.lease_generation + 1,
        attempt_count = j.attempt_count + 1,
        updated_at = v_now
    FROM candidates c
    WHERE j.character_id = c.character_id
    RETURNING j.character_id
  )
  SELECT pg_catalog.array_agg(character_id ORDER BY character_id)
  INTO v_ids
  FROM claimed;

  IF COALESCE(pg_catalog.cardinality(v_ids), 0) = 0 THEN
    RETURN pg_catalog.jsonb_build_object('status', 'no_pending_jobs', 'pending_character_count', v_pending_count);
  END IF;

  INSERT INTO public.encounter_schedule_batch_runs (
    lease_token, status, character_ids, actor_user_id, is_manual, started_at, updated_at
  ) VALUES (
    v_lease, 'processing', v_ids, p_actor_user_id, p_force IS TRUE, v_now, v_now
  )
  RETURNING id INTO v_batch;

  SELECT pg_catalog.jsonb_agg(public.encounter_schedule_source_payload(x.character_id))
  INTO v_characters
  FROM pg_catalog.unnest(v_ids) AS x(character_id);

  RETURN pg_catalog.jsonb_build_object(
    'status', 'claimed',
    'batch_id', v_batch,
    'lease_token', v_lease,
    'characters', COALESCE(v_characters, '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.claim_encounter_schedule_batch(integer, boolean, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_encounter_schedule_batch(integer, boolean, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.fail_encounter_schedule_batch(
  p_batch_id uuid,
  p_lease_token uuid,
  p_failure_code text,
  p_retryable boolean DEFAULT false,
  p_ambiguous boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_batch public.encounter_schedule_batch_runs%ROWTYPE;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_batch
  FROM public.encounter_schedule_batch_runs b
  WHERE b.id = p_batch_id
    AND b.lease_token = p_lease_token
    AND b.status = 'processing'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE public.encounter_schedule_generation_jobs j
  SET status = CASE
        WHEN p_ambiguous IS TRUE THEN 'needs_reconciliation'
        WHEN p_retryable IS TRUE AND j.attempt_count < 3 THEN 'pending'
        ELSE 'failed'
      END,
      available_at = CASE
        WHEN p_ambiguous IS TRUE THEN pg_catalog.clock_timestamp() + interval '6 hours'
        WHEN p_retryable IS TRUE AND j.attempt_count < 3
          THEN pg_catalog.clock_timestamp() + (interval '15 minutes' * GREATEST(j.attempt_count, 1))
        ELSE pg_catalog.clock_timestamp() + interval '24 hours'
      END,
      lease_token = NULL,
      lease_expires_at = NULL,
      last_error_code = LEFT(COALESCE(p_failure_code, 'unknown'), 100),
      updated_at = pg_catalog.clock_timestamp()
  WHERE j.character_id = ANY(v_batch.character_ids)
    AND j.lease_token = p_lease_token
    AND j.status = 'processing';

  UPDATE public.encounter_schedule_batch_runs
  SET status = CASE WHEN p_ambiguous IS TRUE THEN 'needs_reconciliation' ELSE 'failed' END,
      failure_code = LEFT(COALESCE(p_failure_code, 'unknown'), 100),
      completed_at = pg_catalog.clock_timestamp(),
      updated_at = pg_catalog.clock_timestamp()
  WHERE id = p_batch_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.fail_encounter_schedule_batch(uuid, uuid, text, boolean, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_encounter_schedule_batch(uuid, uuid, text, boolean, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.publish_encounter_schedule_batch(
  p_batch_id uuid,
  p_lease_token uuid,
  p_characters jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_batch public.encounter_schedule_batch_runs%ROWTYPE;
  v_item jsonb;
  v_variant jsonb;
  v_slot jsonb;
  v_special_event jsonb;
  v_special_slot jsonb;
  v_special_event_key text;
  v_special_event_name text;
  v_character_id uuid;
  v_job public.encounter_schedule_generation_jobs%ROWTYPE;
  v_source jsonb;
  v_current_hash text;
  v_placement text;
  v_day_type text;
  v_published integer := 0;
  v_unplaced integer := 0;
  v_skipped integer := 0;
  v_output_count integer := 0;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_characters) <> 'array' THEN
    RAISE EXCEPTION 'schedule_batch_output_must_be_array' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_batch
  FROM public.encounter_schedule_batch_runs b
  WHERE b.id = p_batch_id AND b.lease_token = p_lease_token AND b.status = 'processing'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_batch_lease_not_found' USING ERRCODE = '40001';
  END IF;

  SELECT COUNT(*) INTO v_output_count FROM jsonb_array_elements(p_characters);
  IF v_output_count <> pg_catalog.cardinality(v_batch.character_ids) THEN
    RAISE EXCEPTION 'schedule_batch_character_count_mismatch' USING ERRCODE = '22023';
  END IF;

  IF (
    SELECT COUNT(DISTINCT value->>'character_id')
    FROM jsonb_array_elements(p_characters)
  ) <> v_output_count THEN
    RAISE EXCEPTION 'schedule_batch_duplicate_character' USING ERRCODE = '22023';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_characters)
  LOOP
    v_character_id := (v_item->>'character_id')::uuid;
    IF NOT (v_character_id = ANY(v_batch.character_ids)) THEN
      RAISE EXCEPTION 'schedule_batch_contains_unclaimed_character' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_job
    FROM public.encounter_schedule_generation_jobs j
    WHERE j.character_id = v_character_id
      AND j.lease_token = p_lease_token
      AND j.status = 'processing'
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'schedule_character_lease_mismatch' USING ERRCODE = '40001';
    END IF;

    v_source := public.encounter_schedule_source_payload(v_character_id);
    IF v_source IS NULL THEN
      UPDATE public.encounter_schedule_generation_jobs
      SET status = 'cancelled', lease_token = NULL, lease_expires_at = NULL,
          last_error_code = 'character_no_longer_public', updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_current_hash := pg_catalog.md5(v_source::text);
    IF v_current_hash IS DISTINCT FROM v_job.source_hash THEN
      UPDATE public.encounter_schedule_generation_jobs
      SET source_hash = v_current_hash, status = 'pending',
          queued_at = pg_catalog.clock_timestamp(), available_at = pg_catalog.clock_timestamp(),
          lease_token = NULL, lease_expires_at = NULL,
          lease_generation = lease_generation + 1, attempt_count = 0,
          last_error_code = 'source_changed_during_generation', updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_placement := v_item->>'placement';
    IF v_placement = 'no_matching_location' THEN
      IF jsonb_typeof(v_item->'special_events') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'unplaced_character_special_events_must_be_empty' USING ERRCODE = '22023';
      END IF;
      IF jsonb_array_length(v_item->'special_events') <> 0 THEN
        RAISE EXCEPTION 'unplaced_character_special_events_must_be_empty' USING ERRCODE = '22023';
      END IF;
      UPDATE public.character_schedules
      SET is_active = false, updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id AND source_type IN ('ai', 'legacy') AND is_active IS TRUE;

      UPDATE public.encounter_schedule_generation_jobs
      SET status = 'completed', last_completed_source_hash = v_job.source_hash,
          completed_at = pg_catalog.clock_timestamp(), lease_token = NULL, lease_expires_at = NULL,
          last_error_code = NULL, updated_at = pg_catalog.clock_timestamp()
      WHERE character_id = v_character_id;
      v_unplaced := v_unplaced + 1;
      CONTINUE;
    END IF;

    IF v_placement <> 'modern_map' THEN
      RAISE EXCEPTION 'schedule_placement_invalid' USING ERRCODE = '22023';
    END IF;

    UPDATE public.character_schedules
    SET is_active = false, updated_at = pg_catalog.clock_timestamp()
    WHERE character_id = v_character_id AND source_type IN ('ai', 'legacy') AND is_active IS TRUE;

    FOREACH v_day_type IN ARRAY ARRAY['weekday', 'holiday']::text[]
    LOOP
      IF jsonb_typeof(v_item->'variants'->v_day_type) <> 'array'
         OR jsonb_array_length(v_item->'variants'->v_day_type) <> 2 THEN
        RAISE EXCEPTION 'schedule_variants_invalid' USING ERRCODE = '22023';
      END IF;

      FOR v_variant IN SELECT value FROM jsonb_array_elements(v_item->'variants'->v_day_type)
      LOOP
        IF (v_day_type = 'weekday' AND (
              (v_variant->>'variant_key' = 'primary' AND (v_variant->>'weight')::integer <> 80)
              OR (v_variant->>'variant_key' = 'alternative' AND (v_variant->>'weight')::integer <> 20)
            ))
           OR (v_day_type = 'holiday' AND (
              (v_variant->>'variant_key' = 'primary' AND (v_variant->>'weight')::integer <> 60)
              OR (v_variant->>'variant_key' = 'alternative' AND (v_variant->>'weight')::integer <> 40)
            )) THEN
          RAISE EXCEPTION 'schedule_variant_weight_invalid' USING ERRCODE = '22023';
        END IF;

        IF v_variant->>'variant_key' NOT IN ('primary', 'alternative')
           OR jsonb_typeof(v_variant->'slots') <> 'array'
           OR jsonb_array_length(v_variant->'slots') NOT BETWEEN 2 AND 4 THEN
          RAISE EXCEPTION 'schedule_variant_shape_invalid' USING ERRCODE = '22023';
        END IF;

        FOR v_slot IN SELECT value FROM jsonb_array_elements(v_variant->'slots')
        LOOP
          IF COALESCE(v_slot->>'start_time', '') !~ '^([01][0-9]|2[0-3]):00$'
             OR COALESCE(v_slot->>'end_time', '') !~ '^([01][0-9]|2[0-3]):00$'
             OR v_slot->>'start_time' = v_slot->>'end_time'
             OR COALESCE(v_slot->>'location_key', '') NOT IN (
               'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
               'department-store', 'bookstore', 'cafe', 'park', 'shopping-street'
             )
             OR char_length(COALESCE(v_slot->>'activity', '')) NOT BETWEEN 1 AND 200
             OR char_length(COALESCE(v_slot->>'encounter_greeting', '')) NOT BETWEEN 150 AND 300 THEN
            RAISE EXCEPTION 'schedule_slot_invalid' USING ERRCODE = '22023';
          END IF;

          IF COALESCE((v_slot->>'is_outdoor')::boolean, false) IS TRUE THEN
            IF COALESCE(v_slot->>'rain_fallback_location_key', '') NOT IN (
              'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
              'department-store', 'bookstore', 'cafe'
            )
               OR char_length(COALESCE(v_slot->>'rain_fallback_activity', '')) NOT BETWEEN 1 AND 200
               OR char_length(COALESCE(v_slot->>'rain_fallback_greeting', '')) NOT BETWEEN 150 AND 300 THEN
              RAISE EXCEPTION 'schedule_rain_fallback_invalid' USING ERRCODE = '22023';
            END IF;
          ELSE
            IF v_slot->>'rain_fallback_location_key' IS NOT NULL
               OR v_slot->>'rain_fallback_activity' IS NOT NULL
               OR v_slot->>'rain_fallback_greeting' IS NOT NULL THEN
              RAISE EXCEPTION 'schedule_unexpected_rain_fallback' USING ERRCODE = '22023';
            END IF;
          END IF;

          -- Every daily variant must cover 00:00 through the next 00:00
          -- without gaps. A final 22:00-00:00 slot is represented as a wrap to midnight.
          IF EXISTS (
            WITH intervals AS (
              SELECT
                (EXTRACT(HOUR FROM (slot->>'start_time')::time)::integer * 60) AS start_minute,
                (EXTRACT(HOUR FROM (slot->>'end_time')::time)::integer * 60)
                  + CASE
                      WHEN (slot->>'end_time')::time <= (slot->>'start_time')::time THEN 1440
                      ELSE 0
                    END AS end_minute
              FROM jsonb_array_elements(v_variant->'slots') AS slots(slot)
            ),
            ordered AS (
              SELECT start_minute, end_minute,
                pg_catalog.lag(end_minute) OVER (ORDER BY start_minute) AS previous_end
              FROM intervals
            ),
            coverage AS (
              SELECT
                pg_catalog.count(*) AS slot_count,
                pg_catalog.min(start_minute) AS first_start,
                pg_catalog.max(end_minute) AS final_end,
                pg_catalog.bool_or(previous_end IS NOT NULL AND previous_end <> start_minute) AS has_gap
              FROM ordered
            )
            SELECT 1 FROM coverage
            WHERE slot_count < 2 OR first_start <> 0 OR final_end <> 1440 OR COALESCE(has_gap, true)
          ) THEN
            RAISE EXCEPTION 'schedule_variant_24_hour_coverage_incomplete' USING ERRCODE = '22023';
          END IF;

          INSERT INTO public.character_schedules (
            character_id, weekday, day_type, start_time, end_time, location_key, activity,
            priority, is_active, source_type, variant_key, variant_weight,
            encounter_greeting, is_outdoor, rain_fallback_location_key,
            rain_fallback_activity, rain_fallback_greeting, batch_id, source_hash
          ) VALUES (
            v_character_id, NULL, v_day_type,
            (v_slot->>'start_time')::time, (v_slot->>'end_time')::time,
            v_slot->>'location_key', v_slot->>'activity',
            50, true, 'ai', v_variant->>'variant_key', (v_variant->>'weight')::smallint,
            v_slot->>'encounter_greeting', COALESCE((v_slot->>'is_outdoor')::boolean, false),
            NULLIF(v_slot->>'rain_fallback_location_key', ''),
            NULLIF(v_slot->>'rain_fallback_activity', ''),
            NULLIF(v_slot->>'rain_fallback_greeting', ''),
            p_batch_id, v_job.source_hash
          );
        END LOOP;
      END LOOP;
    END LOOP;

    IF jsonb_typeof(v_item->'special_events') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'schedule_special_events_invalid' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(v_item->'special_events') > 4 THEN
      RAISE EXCEPTION 'schedule_special_events_invalid' USING ERRCODE = '22023';
    END IF;

    IF (
      SELECT COUNT(DISTINCT event.value->>'event_key')
      FROM jsonb_array_elements(v_item->'special_events') AS event(value)
    ) <> jsonb_array_length(v_item->'special_events') THEN
      RAISE EXCEPTION 'schedule_special_event_duplicate' USING ERRCODE = '22023';
    END IF;

    FOR v_special_event IN
      SELECT value FROM jsonb_array_elements(v_item->'special_events')
    LOOP
      v_special_event_key := v_special_event->>'event_key';
      v_special_event_name := pg_catalog.btrim(COALESCE(v_special_event->>'event_name', ''));
      IF COALESCE(v_special_event_key, '') NOT IN ('taiwan_public_holiday', 'lunar_new_year', 'valentines_day', 'christmas')
         OR pg_catalog.char_length(v_special_event_name) NOT BETWEEN 1 AND 40
         OR jsonb_typeof(v_special_event->'slots') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'schedule_special_event_shape_invalid' USING ERRCODE = '22023';
      END IF;
      IF jsonb_array_length(v_special_event->'slots') NOT BETWEEN 2 AND 4 THEN
        RAISE EXCEPTION 'schedule_special_event_shape_invalid' USING ERRCODE = '22023';
      END IF;

      FOR v_special_slot IN
        SELECT value FROM jsonb_array_elements(v_special_event->'slots')
      LOOP
        IF COALESCE(v_special_slot->>'start_time', '') !~ '^([01][0-9]|2[0-3]):00$'
           OR COALESCE(v_special_slot->>'end_time', '') !~ '^([01][0-9]|2[0-3]):00$'
           OR v_special_slot->>'start_time' = v_special_slot->>'end_time'
           OR COALESCE(v_special_slot->>'location_key', '') NOT IN (
             'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
             'department-store', 'bookstore', 'cafe', 'park', 'shopping-street'
           )
           OR pg_catalog.char_length(COALESCE(v_special_slot->>'activity', '')) NOT BETWEEN 1 AND 200
           OR pg_catalog.char_length(COALESCE(v_special_slot->>'encounter_greeting', '')) NOT BETWEEN 150 AND 300
           OR jsonb_typeof(v_special_slot->'is_outdoor') IS DISTINCT FROM 'boolean' THEN
          RAISE EXCEPTION 'schedule_special_event_slot_invalid' USING ERRCODE = '22023';
        END IF;

        IF (v_special_slot->>'is_outdoor')::boolean IS TRUE THEN
          IF COALESCE(v_special_slot->>'rain_fallback_location_key', '') NOT IN (
            'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
            'department-store', 'bookstore', 'cafe'
          )
             OR pg_catalog.char_length(COALESCE(v_special_slot->>'rain_fallback_activity', '')) NOT BETWEEN 1 AND 200
             OR pg_catalog.char_length(COALESCE(v_special_slot->>'rain_fallback_greeting', '')) NOT BETWEEN 150 AND 300 THEN
            RAISE EXCEPTION 'schedule_special_event_rain_fallback_invalid' USING ERRCODE = '22023';
          END IF;
        ELSIF v_special_slot->>'rain_fallback_location_key' IS NOT NULL
           OR v_special_slot->>'rain_fallback_activity' IS NOT NULL
           OR v_special_slot->>'rain_fallback_greeting' IS NOT NULL THEN
          RAISE EXCEPTION 'schedule_special_event_unexpected_rain_fallback' USING ERRCODE = '22023';
        END IF;
      END LOOP;

      IF EXISTS (
        WITH intervals AS (
          SELECT
            EXTRACT(HOUR FROM (slot->>'start_time')::time)::integer * 60 AS start_minute,
            EXTRACT(HOUR FROM (slot->>'end_time')::time)::integer * 60
              + CASE WHEN (slot->>'end_time')::time <= (slot->>'start_time')::time THEN 1440 ELSE 0 END AS end_minute
          FROM jsonb_array_elements(v_special_event->'slots') AS slots(slot)
        ),
        ordered AS (
          SELECT start_minute, end_minute,
            pg_catalog.lag(end_minute) OVER (ORDER BY start_minute) AS previous_end
          FROM intervals
        ),
        coverage AS (
          SELECT pg_catalog.count(*) AS slot_count,
            pg_catalog.min(start_minute) AS first_start,
            pg_catalog.max(end_minute) AS final_end,
            pg_catalog.bool_or(previous_end IS NOT NULL AND previous_end <> start_minute) AS has_gap
          FROM ordered
        )
        SELECT 1 FROM coverage
        WHERE slot_count < 2 OR first_start <> 0 OR final_end <> 1440 OR COALESCE(has_gap, true)
      ) THEN
        RAISE EXCEPTION 'schedule_special_event_24_hour_coverage_incomplete' USING ERRCODE = '22023';
      END IF;

      FOR v_special_slot IN
        SELECT value FROM jsonb_array_elements(v_special_event->'slots')
      LOOP
        INSERT INTO public.character_schedules (
          character_id, weekday, day_type, start_time, end_time, location_key, activity,
          priority, is_active, source_type, variant_key, variant_weight, special_event_key,
          encounter_greeting, is_outdoor, rain_fallback_location_key,
          rain_fallback_activity, rain_fallback_greeting, batch_id, source_hash
        ) VALUES (
          v_character_id, NULL, 'any',
          (v_special_slot->>'start_time')::time, (v_special_slot->>'end_time')::time,
          v_special_slot->>'location_key', v_special_slot->>'activity',
          60, true, 'ai', 'special', 100, v_special_event_key,
          v_special_slot->>'encounter_greeting', (v_special_slot->>'is_outdoor')::boolean,
          NULLIF(v_special_slot->>'rain_fallback_location_key', ''),
          NULLIF(v_special_slot->>'rain_fallback_activity', ''),
          NULLIF(v_special_slot->>'rain_fallback_greeting', ''),
          p_batch_id, v_job.source_hash
        );
      END LOOP;
    END LOOP;

    UPDATE public.encounter_schedule_generation_jobs
    SET status = 'completed', last_completed_source_hash = v_job.source_hash,
        completed_at = pg_catalog.clock_timestamp(), lease_token = NULL, lease_expires_at = NULL,
        last_error_code = NULL, updated_at = pg_catalog.clock_timestamp()
    WHERE character_id = v_character_id;
    v_published := v_published + 1;
  END LOOP;

  UPDATE public.encounter_schedule_batch_runs
  SET status = 'completed', completed_at = pg_catalog.clock_timestamp(),
      published_character_count = v_published, unplaced_character_count = v_unplaced,
      skipped_character_count = v_skipped, updated_at = pg_catalog.clock_timestamp()
  WHERE id = p_batch_id;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'completed',
    'published_character_count', v_published,
    'unplaced_character_count', v_unplaced,
    'skipped_private_character_count', v_skipped
  );
END;
$$;

REVOKE ALL ON FUNCTION public.publish_encounter_schedule_batch(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_encounter_schedule_batch(uuid, uuid, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.resolve_encounter_special_event_key(p_date date)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $encounter_special_event$
  SELECT CASE
    WHEN pg_catalog.to_char(p_date, 'MM-DD') = '02-14' THEN 'valentines_day'
    WHEN pg_catalog.to_char(p_date, 'MM-DD') = '12-25' THEN 'christmas'
    WHEN EXISTS (
      SELECT 1
      FROM public.taiwan_calendar_days d
      WHERE d.calendar_date = p_date
        AND d.day_type = 'holiday'
        AND d.holiday_name ~ '(春節|農曆新年|農曆除夕|除夕)'
    ) THEN 'lunar_new_year'
    WHEN EXISTS (
      SELECT 1
      FROM public.taiwan_calendar_days d
      WHERE d.calendar_date = p_date
        AND d.day_type = 'holiday'
        AND NULLIF(pg_catalog.btrim(d.holiday_name), '') IS NOT NULL
    ) THEN 'taiwan_public_holiday'
    ELSE NULL
  END;
$encounter_special_event$;

REVOKE ALL ON FUNCTION public.resolve_encounter_special_event_key(date)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_encounter_special_event_key(date)
  TO service_role;

COMMENT ON FUNCTION public.resolve_encounter_special_event_key(date) IS
  'Resolves only supported conditional schedule keys: Taiwan official named holidays, Valentine day, and Christmas. Character birthdays remain unsupported until a structured character birthday field exists.';

CREATE OR REPLACE FUNCTION public.resolve_encounter_character_schedule(
  p_character_id uuid,
  p_user_id uuid DEFAULT auth.uid(),
  p_location_key text DEFAULT NULL,
  p_at timestamptz DEFAULT pg_catalog.now()
)
RETURNS TABLE (
  schedule_id uuid,
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
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
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_local timestamp;
  v_local_date date;
  v_local_time time;
  v_schedule_date date;
  v_schedule_day integer;
  v_day_type text;
  v_special_event_key text;
  v_variant_roll integer;
  v_primary_weight integer;
  v_variant_key text;
  v_is_raining boolean := false;
  v_weather_text text := '多雲';
  v_row public.character_schedules%ROWTYPE;
  v_decision public.encounter_schedule_weather_decisions%ROWTYPE;
  v_effective_location text;
  v_effective_activity text;
  v_effective_greeting text;
  v_effective_is_outdoor boolean;
  v_start_local timestamp;
  v_end_local timestamp;
BEGIN
  v_local := p_at AT TIME ZONE 'Asia/Taipei';
  v_local_date := v_local::date;
  v_local_time := v_local::time;
  SELECT weather.is_raining, weather.weather_text
    INTO v_is_raining, v_weather_text
  FROM public.get_encounter_city_weather() AS weather;
  v_is_raining := COALESCE(v_is_raining, false);
  v_weather_text := COALESCE(v_weather_text, '多雲');

  -- Keep only recent decisions; old schedule occurrences are no longer resolvable.
  DELETE FROM public.encounter_schedule_weather_decisions d
  USING public.character_schedules s
  WHERE d.schedule_id = s.id
    AND s.character_id = p_character_id
    AND d.scheduled_end_at < (p_at - interval '2 days');

  FOR v_row IN
    SELECT s.*
    FROM public.characters c
    JOIN public.character_schedules s ON s.character_id = c.id
    WHERE c.id = p_character_id
      AND c.visibility = 'public'
      AND c.deleted_at IS NULL
      AND c.review_status = 'approved'
      AND c.rights_confirmed IS TRUE
      AND (
        c.is_nsfw IS NOT TRUE
        OR EXISTS (
          SELECT 1 FROM public.profiles p
          WHERE p.id = p_user_id
            AND p.birthdate IS NOT NULL
            AND p.birthdate <= (CURRENT_DATE - interval '18 years')::date
        )
      )
      AND s.is_active IS TRUE
      AND (
        (s.start_time < s.end_time AND v_local_time >= s.start_time AND v_local_time < s.end_time)
        OR
        (s.start_time > s.end_time AND (v_local_time >= s.start_time OR v_local_time < s.end_time))
      )
    ORDER BY
      CASE s.source_type WHEN 'manual' THEN 3 WHEN 'ai' THEN 2 ELSE 1 END DESC,
      CASE s.special_event_key
        WHEN 'lunar_new_year' THEN 4
        WHEN 'valentines_day' THEN 4
        WHEN 'christmas' THEN 4
        WHEN 'taiwan_public_holiday' THEN 3
        ELSE 0
      END DESC,
      s.priority DESC,
      s.start_time
  LOOP
    v_schedule_date := CASE
      WHEN v_row.start_time > v_row.end_time AND v_local_time < v_row.end_time
        THEN v_local_date - 1
      ELSE v_local_date
    END;
    v_schedule_day := EXTRACT(DOW FROM v_schedule_date)::integer;

    SELECT CASE
      WHEN d.day_type = 'workday' THEN 'weekday'
      WHEN d.day_type = 'holiday' THEN 'holiday'
      WHEN d.calendar_date IS NULL AND v_schedule_day IN (0, 6) THEN 'holiday'
      ELSE 'weekday'
    END INTO v_day_type
    FROM (SELECT v_schedule_date AS calendar_date) current_day
    LEFT JOIN public.taiwan_calendar_days d ON d.calendar_date = current_day.calendar_date;

    v_special_event_key := public.resolve_encounter_special_event_key(v_schedule_date);
    IF v_row.special_event_key IS NOT NULL THEN
      IF v_row.special_event_key IS DISTINCT FROM v_special_event_key
         AND NOT (
           v_row.special_event_key = 'taiwan_public_holiday'
           AND EXISTS (
             SELECT 1
             FROM public.taiwan_calendar_days d
             WHERE d.calendar_date = v_schedule_date
               AND d.day_type = 'holiday'
               AND NULLIF(pg_catalog.btrim(d.holiday_name), '') IS NOT NULL
           )
         ) THEN
        CONTINUE;
      END IF;
    ELSIF v_row.source_type = 'ai' THEN
      IF v_row.day_type <> v_day_type THEN CONTINUE; END IF;
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
      IF v_row.weekday IS NOT NULL AND v_row.weekday <> v_schedule_day THEN CONTINUE; END IF;
      IF NOT (
        v_row.day_type = 'any'
        OR (v_row.day_type = 'weekday' AND v_day_type = 'weekday')
        OR (v_row.day_type = 'weekend' AND v_schedule_day IN (0, 6))
        OR (v_row.day_type = 'holiday' AND v_day_type = 'holiday')
      ) THEN CONTINUE; END IF;
    END IF;

    v_start_local := v_schedule_date + v_row.start_time;
    v_end_local := v_schedule_date + v_row.end_time
      + CASE WHEN v_row.end_time <= v_row.start_time THEN interval '1 day' ELSE interval '0' END;

    SELECT * INTO v_decision
    FROM public.encounter_schedule_weather_decisions d
    WHERE d.schedule_id = v_row.id
      AND d.scheduled_start_at = (v_start_local AT TIME ZONE 'Asia/Taipei');

    IF NOT FOUND THEN
      v_effective_location := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN COALESCE(v_row.rain_fallback_location_key, v_row.location_key)
        ELSE v_row.location_key END;
      v_effective_activity := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN COALESCE(v_row.rain_fallback_activity, v_row.activity)
        ELSE v_row.activity END;
      v_effective_greeting := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN COALESCE(v_row.rain_fallback_greeting, v_row.encounter_greeting)
        ELSE v_row.encounter_greeting END;
      v_effective_is_outdoor := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN false ELSE v_row.is_outdoor END;

      INSERT INTO public.encounter_schedule_weather_decisions (
        schedule_id, scheduled_start_at, scheduled_end_at, location_key, activity,
        encounter_greeting, is_outdoor, decided_weather_text, decided_is_raining
      ) VALUES (
        v_row.id, (v_start_local AT TIME ZONE 'Asia/Taipei'),
        (v_end_local AT TIME ZONE 'Asia/Taipei'),
        v_effective_location, v_effective_activity, v_effective_greeting,
        v_effective_is_outdoor, v_weather_text, v_is_raining
      ) ON CONFLICT ON CONSTRAINT encounter_schedule_weather_decisions_pkey DO NOTHING;

      SELECT * INTO v_decision
      FROM public.encounter_schedule_weather_decisions d
      WHERE d.schedule_id = v_row.id
        AND d.scheduled_start_at = (v_start_local AT TIME ZONE 'Asia/Taipei');
    END IF;

    IF p_location_key IS NOT NULL AND v_decision.location_key <> p_location_key THEN
      CONTINUE;
    END IF;

    RETURN QUERY SELECT
      v_row.id,
      v_schedule_day::smallint,
      v_day_type,
      v_row.start_time,
      v_row.end_time,
      v_decision.location_key,
      v_decision.activity,
      v_row.priority,
      v_row.source_type,
      v_row.variant_key,
      v_row.variant_weight,
      v_decision.encounter_greeting,
      v_decision.is_outdoor,
      v_row.rain_fallback_location_key,
      v_row.rain_fallback_activity,
      v_row.rain_fallback_greeting,
      v_start_local AT TIME ZONE 'Asia/Taipei',
      v_end_local AT TIME ZONE 'Asia/Taipei';
    RETURN;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_encounter_character_schedule(uuid, uuid, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_encounter_character_schedule(uuid, uuid, text, timestamptz)
  TO service_role;

DROP FUNCTION IF EXISTS public.get_encounter_character_schedule(uuid);
CREATE FUNCTION public.get_encounter_character_schedule(p_character_id uuid)
RETURNS TABLE (
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
  priority smallint,
  encounter_greeting text,
  is_outdoor boolean,
  rain_fallback_location_key text,
  rain_fallback_activity text,
  rain_fallback_greeting text,
  source_type text,
  variant_key text,
  variant_weight smallint
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    r.weekday, r.day_type, r.start_time, r.end_time, r.location_key, r.activity,
    r.priority, r.encounter_greeting, r.is_outdoor, r.rain_fallback_location_key,
    r.rain_fallback_activity, r.rain_fallback_greeting, r.source_type, r.variant_key, r.variant_weight
  FROM public.resolve_encounter_character_schedule(p_character_id, auth.uid(), NULL, pg_catalog.now()) r;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_character_schedule(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_character_schedule(uuid) TO anon, authenticated;

DROP FUNCTION IF EXISTS public.get_encounter_character_schedules(uuid[]);
CREATE FUNCTION public.get_encounter_character_schedules(p_character_ids uuid[])
RETURNS TABLE (
  character_id uuid,
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
  priority smallint,
  encounter_greeting text,
  is_outdoor boolean,
  rain_fallback_location_key text,
  rain_fallback_activity text,
  rain_fallback_greeting text,
  source_type text,
  variant_key text,
  variant_weight smallint
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    ids.character_id,
    r.weekday, r.day_type, r.start_time, r.end_time, r.location_key, r.activity,
    r.priority, r.encounter_greeting, r.is_outdoor, r.rain_fallback_location_key,
    r.rain_fallback_activity, r.rain_fallback_greeting, r.source_type, r.variant_key, r.variant_weight
  FROM (
    SELECT DISTINCT unnest(p_character_ids) AS character_id
  ) ids
  CROSS JOIN LATERAL public.resolve_encounter_character_schedule(
    ids.character_id, auth.uid(), NULL, pg_catalog.now()
  ) r
  WHERE p_character_ids IS NOT NULL
    AND pg_catalog.cardinality(p_character_ids) BETWEEN 1 AND 10;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_character_schedules(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_character_schedules(uuid[]) TO anon, authenticated;

-- The city map needs exactly one schedule per character: the variant valid now in Taiwan,
-- already resolved for weekday/holiday, primary/alternative, and rain fallback.
-- Preserve the existing 16-column RPC return contract; current map UI consumes its first eight fields.
CREATE OR REPLACE FUNCTION public.get_encounter_character_schedules(p_character_ids uuid[])
RETURNS TABLE (
  character_id uuid,
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
  priority smallint,
  encounter_greeting text,
  is_outdoor boolean,
  rain_fallback_location_key text,
  rain_fallback_activity text,
  rain_fallback_greeting text,
  source_type text,
  variant_key text,
  variant_weight smallint
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    c.id,
    resolved.weekday,
    resolved.day_type,
    resolved.start_time,
    resolved.end_time,
    resolved.location_key,
    resolved.activity,
    resolved.priority,
    resolved.encounter_greeting,
    resolved.is_outdoor,
    resolved.rain_fallback_location_key,
    resolved.rain_fallback_activity,
    resolved.rain_fallback_greeting,
    resolved.source_type,
    resolved.variant_key,
    resolved.variant_weight
  FROM (
    SELECT DISTINCT requested.character_id
    FROM pg_catalog.unnest(p_character_ids) AS requested(character_id)
    WHERE requested.character_id IS NOT NULL
  ) AS requested
  JOIN public.characters c ON c.id = requested.character_id
  CROSS JOIN LATERAL public.resolve_encounter_character_schedule(
    c.id,
    (SELECT auth.uid()),
    NULL,
    pg_catalog.now()
  ) AS resolved
  WHERE p_character_ids IS NOT NULL
    AND pg_catalog.cardinality(p_character_ids) BETWEEN 1 AND 10
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL
  ORDER BY c.id, resolved.priority DESC, resolved.start_time;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_character_schedules(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_character_schedules(uuid[]) TO anon, authenticated;

COMMENT ON FUNCTION public.get_encounter_character_schedules(uuid[]) IS
  'Returns current Taiwan-time schedules for supplied public characters. Rain fallback is decided once per schedule slot and persisted until that slot ends, so later weather changes never move a character mid-slot. Preserves the original 16-column RPC contract and 10-ID batch limit.';

CREATE OR REPLACE FUNCTION public.save_character_schedules(
  p_character_id uuid,
  p_schedules jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_count integer;
BEGIN
  IF v_uid IS NULL OR public.account_is_active() IS NOT TRUE THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_character_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.characters c
    WHERE c.id = p_character_id AND c.author_id = v_uid AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Character not found or not owned by caller' USING ERRCODE = '42501';
  END IF;

  IF p_schedules IS NULL OR jsonb_typeof(p_schedules) <> 'array' THEN
    RAISE EXCEPTION 'Schedules must be a JSON array' USING ERRCODE = '22023';
  END IF;

  v_count := jsonb_array_length(p_schedules);
  IF v_count > 50 THEN
    RAISE EXCEPTION 'At most 50 schedule rows are allowed' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_schedules) AS e(value)
    WHERE jsonb_typeof(e.value) <> 'object'
      OR (e.value ? 'weekday' AND e.value->'weekday' <> 'null'::jsonb
          AND (jsonb_typeof(e.value->'weekday') <> 'number'
               OR (e.value->>'weekday') !~ '^[0-6]$'))
      OR COALESCE(e.value->>'day_type', 'any') NOT IN ('any', 'weekday', 'weekend', 'holiday')
      OR COALESCE(e.value->>'start_time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      OR COALESCE(e.value->>'end_time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      OR COALESCE(e.value->>'start_time', '') = COALESCE(e.value->>'end_time', '')
      OR COALESCE(e.value->>'location_key', '') !~ '^[A-Za-z0-9_-]{1,80}$'
      OR char_length(COALESCE(e.value->>'activity', '')) NOT BETWEEN 1 AND 300
  ) THEN
    RAISE EXCEPTION 'One or more schedule rows are invalid' USING ERRCODE = '22023';
  END IF;

  -- Preserve AI-published and legacy rows. This RPC replaces only explicit
  -- author-managed rows; manual rows win resolver priority over AI rows.
  DELETE FROM public.character_schedules
  WHERE character_id = p_character_id AND source_type = 'manual';

  INSERT INTO public.character_schedules (
    character_id, weekday, day_type, start_time, end_time,
    location_key, activity, priority, is_active, source_type,
    variant_key, variant_weight, encounter_greeting, is_outdoor,
    rain_fallback_location_key, rain_fallback_activity, rain_fallback_greeting
  )
  SELECT
    p_character_id, x.weekday, COALESCE(x.day_type, 'any'),
    x.start_time::time, x.end_time::time, x.location_key, x.activity,
    100, true, 'manual', 'primary', 100, '', false, NULL, NULL, NULL
  FROM jsonb_to_recordset(p_schedules) AS x(
    weekday smallint, day_type text, start_time text, end_time text,
    location_key text, activity text
  );

  -- Re-enqueue only through the author-facing RPC; AI publication writes are not retriggered.
  PERFORM public.enqueue_encounter_schedule_generation_internal(p_character_id);
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.save_character_schedules(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_character_schedules(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_encounter_city_weather()
RETURNS TABLE (
  weather_text text,
  temperature_c numeric,
  is_raining boolean,
  precipitation_1h_mm numeric,
  observed_at timestamptz,
  weather_source text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $encounter_city_weather$
  WITH latest AS (
    SELECT w.*
    FROM public.encounter_city_weather w
    WHERE w.city_key = 'taipei'
    ORDER BY w.fetched_at DESC
    LIMIT 1
  )
  SELECT
    COALESCE(latest.weather_text, '多雲'),
    COALESCE(latest.temperature_c, 24::numeric),
    COALESCE(latest.is_raining, false),
    latest.precipitation_1h_mm,
    COALESCE(latest.observed_at, latest.fetched_at),
    COALESCE(latest.source, 'poyozz_fallback')
  FROM (SELECT 1) AS seed
  LEFT JOIN latest ON true;
$encounter_city_weather$;

REVOKE ALL ON FUNCTION public.get_encounter_city_weather() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_city_weather() TO anon, authenticated, service_role;

COMMENT ON TABLE public.encounter_city_weather IS
  'One cached fictional Taipei weather state generated every six hours; no external weather API, forecast, or historical baseline dependency.';

CREATE OR REPLACE FUNCTION public.get_encounter_scene_registry()
RETURNS TABLE (
  location_key text,
  display_name text,
  icon text,
  marker_x integer,
  marker_y integer,
  heading text,
  description text,
  event_label text,
  event_title text,
  event_description text,
  character_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $encounter_scene_registry$
  SELECT
    r.location_key,
    r.display_name,
    r.icon,
    r.marker_x,
    r.marker_y,
    r.heading,
    r.description,
    r.event_label,
    r.event_title,
    r.event_description,
    pg_catalog.count(DISTINCT c.id) AS character_count
  FROM public.encounter_scene_registry r
  JOIN public.character_schedules s
    ON s.location_key = r.location_key
   AND s.is_active IS TRUE
   AND s.special_event_key IS NULL
  JOIN public.characters c ON c.id = s.character_id
  WHERE r.is_dynamic IS TRUE
    AND r.is_active IS TRUE
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL
    AND (
      c.is_nsfw IS NOT TRUE
      OR ((SELECT auth.uid()) IS NOT NULL AND private.current_user_is_adult())
    )
  GROUP BY
    r.location_key, r.display_name, r.icon, r.marker_x, r.marker_y,
    r.heading, r.description, r.event_label, r.event_title,
    r.event_description, r.minimum_character_count, r.display_order
  HAVING pg_catalog.count(DISTINCT c.id) >= r.minimum_character_count
  ORDER BY r.display_order, r.location_key
  LIMIT 3;
$encounter_scene_registry$;

REVOKE ALL ON FUNCTION public.get_encounter_scene_registry() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_scene_registry() TO anon, authenticated;

COMMENT ON FUNCTION public.get_encounter_scene_registry() IS
  'Returns only allowlisted dynamic city-scene markers whose published schedules are shared by the configured minimum number of eligible public characters. Coordinates and scene metadata come only from the server-owned registry.';

CREATE OR REPLACE FUNCTION public.schedule_encounter_worker(
  p_worker text,
  p_enabled boolean DEFAULT false
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $encounter_worker_scheduler$
DECLARE
  v_job_name text;
  v_cron_schedule text;
  v_endpoint text;
  v_timeout integer;
  v_project_url text;
  v_service_key text;
  v_job_id bigint;
  v_command text;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  CASE p_worker
    WHEN 'schedule_organizer' THEN
      v_job_name := 'poyozz-encounter-schedule-organizer';
      v_cron_schedule := '*/15 * * * *';
      v_endpoint := 'encounter-schedule-organizer';
      v_timeout := 120000;
    WHEN 'weather_sync' THEN
      v_job_name := 'poyozz-encounter-weather-sync';
      v_cron_schedule := '0 */6 * * *';
      v_endpoint := 'encounter-weather-sync';
      v_timeout := 30000;
    WHEN 'taiwan_calendar_sync' THEN
      v_job_name := 'poyozz-encounter-taiwan-calendar-sync';
      v_cron_schedule := '0 19 1 * *';
      v_endpoint := 'encounter-taiwan-calendar-sync';
      v_timeout := 30000;
    ELSE
      RAISE EXCEPTION 'encounter_worker_not_allowed' USING ERRCODE = '22023';
  END CASE;

  IF to_regclass('cron.job') IS NULL
     OR to_regclass('vault.decrypted_secrets') IS NULL
     OR to_regprocedure('cron.schedule(text,text,text)') IS NULL
     OR to_regprocedure('cron.unschedule(bigint)') IS NULL
     OR to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') IS NULL THEN
    RETURN 'scheduler_extensions_missing';
  END IF;

  IF p_enabled IS NOT TRUE THEN
    FOR v_job_id IN
      SELECT jobid FROM cron.job WHERE jobname = v_job_name
    LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;
    RETURN 'disabled:' || v_job_name;
  END IF;

  SELECT decrypted_secret INTO v_project_url
  FROM vault.decrypted_secrets WHERE name = 'poyozz_supabase_url' LIMIT 1;
  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'poyozz_service_role_key' LIMIT 1;

  IF COALESCE(v_project_url, '') !~ '^https://[a-zA-Z0-9-]+[.]supabase[.]co/?$'
     OR COALESCE(v_service_key, '') = '' THEN
    RETURN 'vault_secrets_missing';
  END IF;

  v_command := pg_catalog.format(
    $encounter_cron_command$
      SELECT net.http_post(
        url := regexp_replace(
          (SELECT decrypted_secret FROM vault.decrypted_secrets
           WHERE name = 'poyozz_supabase_url' LIMIT 1),
          '/+$', ''
        ) || '/functions/v1/%s',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || (
            SELECT decrypted_secret FROM vault.decrypted_secrets
            WHERE name = 'poyozz_service_role_key' LIMIT 1
          ),
          'Content-Type', 'application/json'
        ),
        body := '{"mode":"scheduled"}'::jsonb,
        timeout_milliseconds := %s
      );
    $encounter_cron_command$,
    v_endpoint,
    v_timeout
  );

  FOR v_job_id IN
    SELECT jobid FROM cron.job WHERE jobname = v_job_name
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;

  PERFORM cron.schedule(v_job_name, v_cron_schedule, v_command);
  RETURN 'scheduled:' || v_job_name || ':' || v_cron_schedule;
END;
$encounter_worker_scheduler$;

REVOKE ALL ON FUNCTION public.schedule_encounter_worker(text, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_worker(text, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.schedule_encounter_schedule_organizer(
  p_enabled boolean DEFAULT false
)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $schedule_organizer_wrapper$
  SELECT public.schedule_encounter_worker('schedule_organizer', p_enabled);
$schedule_organizer_wrapper$;

CREATE OR REPLACE FUNCTION public.schedule_encounter_weather_sync(
  p_enabled boolean DEFAULT false
)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $weather_sync_wrapper$
  SELECT public.schedule_encounter_worker('weather_sync', p_enabled);
$weather_sync_wrapper$;

CREATE OR REPLACE FUNCTION public.schedule_encounter_taiwan_calendar_sync(
  p_enabled boolean DEFAULT false
)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $calendar_sync_wrapper$
  SELECT public.schedule_encounter_worker('taiwan_calendar_sync', p_enabled);
$calendar_sync_wrapper$;

REVOKE ALL ON FUNCTION public.schedule_encounter_schedule_organizer(boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.schedule_encounter_weather_sync(boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.schedule_encounter_taiwan_calendar_sync(boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_schedule_organizer(boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_weather_sync(boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_taiwan_calendar_sync(boolean) TO service_role;

COMMENT ON TABLE public.encounter_schedule_generation_jobs IS
  'Service-role-only unique-per-character queue. Enqueue triggers run on author schedule-description changes and public eligibility changes. Threshold counts distinct public approved characters; a 23h45m fallback trigger plus 15-minute cron interval keeps the nominal maximum under 24 hours before global rate limits.';
COMMENT ON TABLE public.encounter_schedule_batch_runs IS
  'Global schedule AI batch ledger enforcing six-hour cooldown and four batches per Taipei calendar day.';
COMMENT ON TABLE public.encounter_scene_registry IS
  'Server-owned allowlist for city-map scene markers. V1 exposes the shared shopping-street scene only after at least two eligible public characters use it; AI never supplies coordinates.';
COMMENT ON TABLE public.taiwan_calendar_days IS
  'Taiwan government office calendar dates, including official holidays and make-up workdays. Synced from the published government calendar dataset.';
COMMENT ON TABLE public.encounter_city_weather IS
  'One cached fictional Taipei weather state generated every six hours; no external weather API, forecast, or historical baseline dependency.';
COMMENT ON FUNCTION public.schedule_encounter_worker(text, boolean) IS
  'Allowlisted opt-in scheduler for Encounter background workers. No jobs are activated by migration.';
COMMENT ON FUNCTION public.schedule_encounter_schedule_organizer(boolean) IS
  'Opt-in 15-minute schedule organizer cron wrapper; manual test trigger is separate.';
COMMENT ON FUNCTION public.schedule_encounter_weather_sync(boolean) IS
  'Opt-in six-hour deterministic seasonal Taipei weather simulation; no external weather API or historical baseline.';
COMMENT ON FUNCTION public.schedule_encounter_taiwan_calendar_sync(boolean) IS
  'Opt-in monthly Taiwan official calendar refresh wrapper. Runs at 03:00 Asia/Taipei on the first day of each month.';

COMMIT;
