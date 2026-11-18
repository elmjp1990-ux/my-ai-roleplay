BEGIN;

-- Keep every valid AI schedule row as the durable intent. Availability is a
-- read-time projection from the server-owned scene catalog, not a reason to
-- discard or regenerate the AI schedule.
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
      -- character_schedules stores the complete AI intent, including locations
      -- that are not currently encounterable. Only resolve rows whose scene is
      -- presently exposed by the server-owned catalog. Adding/enabling a scene
      -- makes the retained intent resolvable without another AI request.
      AND EXISTS (
        SELECT 1
        FROM public.get_encounter_scene_catalog() AS available_scene
        WHERE available_scene.location_key = s.location_key
      )
      -- Ignore the old pre-AI placeholder rows (all-day, every-place, priority 0).
      -- Keep the historical rows intact; only prevent them from being treated as live schedules.
      AND NOT (
        s.source_type = 'legacy'
        AND s.start_time = TIME '00:00'
        AND s.end_time = TIME '23:59'
        AND COALESCE(s.priority, 0) = 0
      )
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

COMMENT ON FUNCTION public.resolve_encounter_character_schedule(uuid, uuid, text, timestamptz) IS
  'Resolves stored schedule intent only when its scene is currently exposed by get_encounter_scene_catalog(). Newly enabled scenes automatically expose matching stored slots without AI regeneration.';

COMMIT;
