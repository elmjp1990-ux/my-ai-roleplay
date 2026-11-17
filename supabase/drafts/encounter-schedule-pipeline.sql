-- DRAFT ONLY: Encounter schedule AI pipeline.
-- Do not apply directly to a hosted project. After review, create the migration
-- with `supabase migration new encounter_schedule_pipeline`, move this SQL into
-- the generated migration, and validate on disposable local Supabase first.

BEGIN;

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
  CHECK (variant_key IN ('primary', 'alternative'));
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

CREATE TABLE IF NOT EXISTS public.taiwan_calendar_days (
  calendar_date date PRIMARY KEY,
  day_type text NOT NULL CHECK (day_type IN ('holiday', 'workday')),
  holiday_name text,
  source text NOT NULL DEFAULT 'government_calendar',
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

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

ALTER TABLE public.encounter_schedule_generation_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_schedule_batch_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_schedule_generation_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taiwan_calendar_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter_scene_registry ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.encounter_schedule_generation_jobs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_schedule_batch_runs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_schedule_generation_usage FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.taiwan_calendar_days FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.encounter_scene_registry FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_schedule_generation_jobs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_schedule_batch_runs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.encounter_schedule_generation_usage TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.taiwan_calendar_days TO service_role;

GRANT SELECT ON TABLE public.taiwan_calendar_days TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.encounter_schedule_source_payload(p_character_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'character_id', c.id::text,
    'author_id', d.author_id::text,
    'visibility', c.visibility,
    'review_status', c.review_status,
    'rights_confirmed', c.rights_confirmed,
    'deleted_at', c.deleted_at,
    'name', c.name,
    'intro', COALESCE(c.intro, ''),
    'race', COALESCE(c.race, ''),
    'style', COALESCE(c.style, ''),
    'gender', COALESCE(c.gender, ''),
    'age', COALESCE(c.age::text, ''),
    'tags', COALESCE(pg_catalog.to_jsonb(c.tags), '[]'::jsonb),
    'occupation', COALESCE(c.personality_profile ->> 'occupation', ''),
    'world_era', pg_catalog.concat_ws(' ', c.intro, c.race, c.style),
    'modern_setting_compatible',
      pg_catalog.concat_ws(' ', c.intro, d.description, p.private_info, c.personality_profile::text)
      ~ '(現代世界|現代背景|現代都市|現代社會|現代生活|當代)',
    'time_travel_explicit',
      pg_catalog.concat_ws(' ', c.intro, d.description, p.private_info, c.personality_profile::text)
      ~ '(穿越到現代|穿越至現代|來到現代|時空旅行到現代|穿越現代)',
    'schedule_description', d.description,
    'private_info', COALESCE(p.private_info, ''),
    'personality_profile', COALESCE(c.personality_profile, '{}'::jsonb)
  )
  FROM public.characters c
  JOIN public.character_schedule_descriptions d
    ON d.character_id = c.id AND d.author_id = c.author_id
  LEFT JOIN public.character_private_info p
    ON p.character_id = c.id AND p.author_id = c.author_id
  WHERE c.id = p_character_id
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL
    AND pg_catalog.btrim(COALESCE(d.description, '')) <> '';
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
  IF OLD.visibility IS DISTINCT FROM NEW.visibility
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
AFTER UPDATE OF visibility, review_status, rights_confirmed, deleted_at
ON public.characters
FOR EACH ROW EXECUTE FUNCTION public.on_encounter_character_visibility_changed();

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
  JOIN public.character_schedule_descriptions d
    ON d.character_id = j.character_id AND d.author_id = j.author_id
  WHERE j.status IN ('pending', 'failed', 'needs_reconciliation')
    AND (p_force IS TRUE OR j.available_at <= v_now)
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL
    AND pg_catalog.btrim(COALESCE(d.description, '')) <> '';

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
    JOIN public.character_schedule_descriptions d
      ON d.character_id = j.character_id AND d.author_id = j.author_id
    WHERE j.status IN ('pending', 'failed', 'needs_reconciliation')
      AND (p_force IS TRUE OR j.available_at <= v_now)
      AND (p_force IS TRUE OR j.attempt_count < 3 OR j.status = 'needs_reconciliation')
      AND c.visibility = 'public'
      AND c.review_status = 'approved'
      AND c.rights_confirmed IS TRUE
      AND c.deleted_at IS NULL
      AND pg_catalog.btrim(COALESCE(d.description, '')) <> ''
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
STABLE
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
  v_variant_roll integer;
  v_primary_weight integer;
  v_variant_key text;
  v_is_raining boolean := false;
  v_row public.character_schedules%ROWTYPE;
  v_start_local timestamp;
  v_end_local timestamp;
BEGIN
  v_local := p_at AT TIME ZONE 'Asia/Taipei';
  v_local_date := v_local::date;
  v_local_time := v_local::time;

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
        p_location_key IS NULL
        OR s.location_key = p_location_key
        OR (v_is_raining IS TRUE AND s.is_outdoor IS TRUE AND s.rain_fallback_location_key = p_location_key)
      )
      AND (
        (s.start_time < s.end_time AND v_local_time >= s.start_time AND v_local_time < s.end_time)
        OR
        (s.start_time > s.end_time AND (v_local_time >= s.start_time OR v_local_time < s.end_time))
      )
    ORDER BY
      CASE s.source_type WHEN 'manual' THEN 3 WHEN 'ai' THEN 2 ELSE 1 END DESC,
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

    IF v_row.source_type = 'ai' THEN
      IF v_row.day_type <> v_day_type THEN CONTINUE; END IF;
      SELECT s.variant_weight INTO v_primary_weight
      FROM public.character_schedules s
      WHERE s.character_id = p_character_id
        AND s.source_type = 'ai'
        AND s.is_active IS TRUE
        AND s.day_type = v_day_type
        AND s.variant_key = 'primary'
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

    IF p_location_key IS NOT NULL
       AND v_row.location_key <> p_location_key
       AND NOT (v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE AND v_row.rain_fallback_location_key = p_location_key) THEN
      CONTINUE;
    END IF;

    v_start_local := v_schedule_date + v_row.start_time;
    v_end_local := v_schedule_date + v_row.end_time
      + CASE WHEN v_row.end_time <= v_row.start_time THEN interval '1 day' ELSE interval '0' END;

    RETURN QUERY SELECT
      v_row.id,
      NULL::smallint,
      v_row.day_type,
      v_row.start_time,
      v_row.end_time,
      CASE WHEN v_is_raining IS TRUE AND p_location_key = v_row.rain_fallback_location_key
        THEN v_row.rain_fallback_location_key ELSE v_row.location_key END,
      CASE WHEN v_is_raining IS TRUE AND p_location_key = v_row.rain_fallback_location_key
        THEN v_row.rain_fallback_activity ELSE v_row.activity END,
      v_row.priority,
      v_row.source_type,
      v_row.variant_key,
      v_row.variant_weight,
      CASE WHEN v_is_raining IS TRUE AND p_location_key = v_row.rain_fallback_location_key
        THEN v_row.rain_fallback_greeting ELSE v_row.encounter_greeting END,
      v_row.is_outdoor,
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
STABLE
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
STABLE
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

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.save_character_schedules(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_character_schedules(uuid, jsonb) TO authenticated;

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
AS $
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
    ON s.location_key = r.location_key AND s.is_active IS TRUE
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
  ORDER BY r.display_order, r.location_key;
$;

REVOKE ALL ON FUNCTION public.get_encounter_scene_registry() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_scene_registry() TO anon, authenticated;

COMMENT ON FUNCTION public.get_encounter_scene_registry() IS
  'Returns only allowlisted dynamic city-scene markers whose published schedules are shared by the configured minimum number of eligible public characters. Coordinates and scene metadata come only from the server-owned registry.';

CREATE OR REPLACE FUNCTION public.schedule_encounter_schedule_organizer(
  p_enabled boolean DEFAULT false
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_project_url text;
  v_service_key text;
  v_job_id bigint;
  v_command text;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  IF to_regclass('cron.job') IS NULL
     OR to_regclass('vault.decrypted_secrets') IS NULL
     OR to_regprocedure('cron.schedule(text,text,text)') IS NULL
     OR to_regprocedure('cron.unschedule(bigint)') IS NULL
     OR to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') IS NULL THEN
    RETURN 'scheduler_extensions_missing';
  END IF;

  IF p_enabled IS NOT TRUE THEN
    FOR v_job_id IN
      SELECT jobid FROM cron.job
      WHERE jobname = 'poyozz-encounter-schedule-organizer'
    LOOP
      PERFORM cron.unschedule(v_job_id);
    END LOOP;
    RETURN 'disabled';
  END IF;

  SELECT decrypted_secret INTO v_project_url
  FROM vault.decrypted_secrets WHERE name = 'poyozz_supabase_url' LIMIT 1;
  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'poyozz_service_role_key' LIMIT 1;

  IF COALESCE(v_project_url, '') !~ '^https://[a-zA-Z0-9-]+[.]supabase[.]co/?$'
     OR COALESCE(v_service_key, '') = '' THEN
    RETURN 'vault_secrets_missing';
  END IF;

  v_command := $command$
    SELECT net.http_post(
      url := regexp_replace(
        (SELECT decrypted_secret FROM vault.decrypted_secrets
         WHERE name = 'poyozz_supabase_url' LIMIT 1),
        '/+$', ''
      ) || '/functions/v1/encounter-schedule-organizer',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (
          SELECT decrypted_secret FROM vault.decrypted_secrets
          WHERE name = 'poyozz_service_role_key' LIMIT 1
        ),
        'Content-Type', 'application/json'
      ),
      body := '{"mode":"scheduled"}'::jsonb,
      timeout_milliseconds := 120000
    );
  $command$;

  FOR v_job_id IN
    SELECT jobid FROM cron.job
    WHERE jobname = 'poyozz-encounter-schedule-organizer'
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;

  PERFORM cron.schedule(
    'poyozz-encounter-schedule-organizer',
    '*/15 * * * *',
    v_command
  );

  RETURN 'scheduled';
END;
$$;

REVOKE ALL ON FUNCTION public.schedule_encounter_schedule_organizer(boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_encounter_schedule_organizer(boolean) TO service_role;

COMMENT ON TABLE public.encounter_schedule_generation_jobs IS
  'Service-role-only unique-per-character queue. Enqueue triggers run on author schedule-description changes and public eligibility changes. Threshold counts distinct public approved characters; a 23h45m fallback trigger plus 15-minute cron interval keeps the nominal maximum under 24 hours before global rate limits.';
COMMENT ON TABLE public.encounter_schedule_batch_runs IS
  'Global schedule AI batch ledger enforcing six-hour cooldown and four batches per Taipei calendar day.';
COMMENT ON TABLE public.encounter_scene_registry IS
  'Server-owned allowlist for city-map scene markers. V1 exposes only the shared shopping-street scene after at least two eligible public characters use it; AI never supplies coordinates.';
COMMENT ON TABLE public.taiwan_calendar_days IS
  'Taiwan official workday/holiday overrides, including make-up workdays. Empty table falls back to weekend/weekday until official calendar data is seeded.';
COMMENT ON FUNCTION public.schedule_encounter_schedule_organizer(boolean) IS
  'Opt-in pg_cron scheduler. Migration does not activate it; a service-role operator must explicitly enable it after Edge Function and Vault secrets are verified.';

COMMIT;
