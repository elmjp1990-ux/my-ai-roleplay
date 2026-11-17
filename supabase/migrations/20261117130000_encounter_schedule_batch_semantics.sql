-- Schedule batch semantics: threshold + 24h oldest-job trigger, six-hour cooldown
-- measured from the last successful completion, and per-character idempotent publishing.
-- Source-only until explicitly applied to Hosted Supabase.

CREATE OR REPLACE FUNCTION public.claim_encounter_schedule_batch(
  p_limit integer DEFAULT 2147483647,
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
  v_limit integer := GREATEST(COALESCE(p_limit, 2147483647), 1);
  v_pending_count integer := 0;
  v_oldest timestamptz;
  v_last_completed timestamptz;
  v_lease uuid := gen_random_uuid();
  v_batch uuid;
  v_ids uuid[];
  v_characters jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
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
       AND (v_oldest IS NULL OR v_oldest > v_now - interval '24 hours') THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'waiting_threshold',
        'pending_character_count', v_pending_count,
        'oldest_queued_at', v_oldest
      );
    END IF;

    SELECT MAX(b.completed_at) INTO v_last_completed
    FROM public.encounter_schedule_batch_runs b
    WHERE b.status = 'completed'
      AND b.completed_at IS NOT NULL;

    IF v_last_completed IS NOT NULL
       AND v_last_completed > v_now - interval '6 hours' THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'cooldown',
        'pending_character_count', v_pending_count,
        'next_eligible_at', v_last_completed + interval '6 hours'
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
  v_remaining_count integer := 0;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
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
  IF v_output_count < 1 OR v_output_count > pg_catalog.cardinality(v_batch.character_ids) THEN
    RAISE EXCEPTION 'schedule_batch_character_count_invalid' USING ERRCODE = '22023';
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

  SELECT pg_catalog.count(*)::integer INTO v_remaining_count
  FROM public.encounter_schedule_generation_jobs j
  WHERE j.character_id = ANY(v_batch.character_ids)
    AND j.lease_token = p_lease_token
    AND j.status = 'processing';

  IF v_remaining_count = 0 THEN
    UPDATE public.encounter_schedule_batch_runs
    SET status = 'completed', completed_at = pg_catalog.clock_timestamp(),
        published_character_count = published_character_count + v_published,
        unplaced_character_count = unplaced_character_count + v_unplaced,
        skipped_character_count = skipped_character_count + v_skipped,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = p_batch_id;
  ELSE
    UPDATE public.encounter_schedule_batch_runs
    SET published_character_count = published_character_count + v_published,
        unplaced_character_count = unplaced_character_count + v_unplaced,
        skipped_character_count = skipped_character_count + v_skipped,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = p_batch_id;
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'status', CASE WHEN v_remaining_count = 0 THEN 'completed' ELSE 'partial' END,
    'published_character_count', v_published,
    'unplaced_character_count', v_unplaced,
    'skipped_private_character_count', v_skipped,
    'remaining_character_count', v_remaining_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.publish_encounter_schedule_batch(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_encounter_schedule_batch(uuid, uuid, jsonb) TO service_role;


COMMENT ON TABLE public.encounter_schedule_batch_runs IS
  'Service-role-only batch ledger. Automatic runs require at least 10 pending jobs or an oldest pending job aged 24 hours; a global six-hour cooldown starts at the previous successful batch completion. No daily execution cap.';

COMMENT ON TABLE public.encounter_schedule_generation_jobs IS
  'Service-role-only unique-per-character queue. Eligible pending jobs accumulate during cooldown. The oldest pending job triggers at 24 hours; at least 10 pending jobs trigger sooner, subject to the global six-hour cooldown.';
