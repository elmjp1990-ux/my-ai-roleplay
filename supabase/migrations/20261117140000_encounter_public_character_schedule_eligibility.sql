-- Include every approved public character in Encounter schedule generation.
-- NSFW visibility is enforced per viewer by the scene catalog and public schedule RPCs.

CREATE OR REPLACE FUNCTION public.enqueue_encounter_schedule_generation_test_batch(
  p_limit integer DEFAULT 2147483647
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_character record;
  v_result jsonb;
  v_limit integer := GREATEST(1, COALESCE(p_limit, 2147483647));
  v_scanned integer := 0;
  v_pending integer := 0;
  v_unchanged integer := 0;
  v_not_eligible integer := 0;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  FOR v_character IN
    SELECT c.id
    FROM public.characters c
    CROSS JOIN LATERAL (
      SELECT public.encounter_schedule_source_payload(c.id) AS payload
    ) src
    WHERE c.author_id IS NOT NULL
      AND c.visibility = 'public'
      AND c.review_status = 'approved'
      AND c.rights_confirmed IS TRUE
      AND c.deleted_at IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.encounter_schedule_generation_jobs j
        WHERE j.character_id = c.id
          AND j.status = 'processing'
          AND j.lease_expires_at > pg_catalog.clock_timestamp()
      )
    ORDER BY c.first_published_at NULLS LAST, c.id
    LIMIT v_limit
  LOOP
    v_scanned := v_scanned + 1;
    v_result := public.enqueue_encounter_schedule_generation_internal(v_character.id);
    CASE COALESCE(v_result->>'status', '')
      WHEN 'pending' THEN v_pending := v_pending + 1;
      WHEN 'failed' THEN v_pending := v_pending + 1;
      WHEN 'needs_reconciliation' THEN v_pending := v_pending + 1;
      WHEN 'not_eligible' THEN v_not_eligible := v_not_eligible + 1;
      ELSE v_unchanged := v_unchanged + 1;
    END CASE;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'scanned_character_count', v_scanned,
    'pending_character_count', v_pending,
    'unchanged_character_count', v_unchanged,
    'not_eligible_character_count', v_not_eligible,
    'limit', v_limit
  );
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_encounter_schedule_generation_test_batch(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_encounter_schedule_generation_test_batch(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.publish_encounter_scene_metadata(p_scenes jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scene jsonb;
  v_key text;
  v_name text;
  v_icon text;
  v_heading text;
  v_description text;
  v_event_label text;
  v_event_title text;
  v_event_description text;
  v_dynamic boolean;
  v_x integer;
  v_y integer;
  v_count integer;
  v_visible_dynamic_count integer;
  v_published integer := 0;
  v_skipped integer := 0;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_scenes) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'scene_metadata_array_invalid' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_scenes) > 26 THEN
    RAISE EXCEPTION 'scene_metadata_array_invalid' USING ERRCODE = '22023';
  END IF;
  IF (
    SELECT pg_catalog.count(*) FROM jsonb_array_elements(p_scenes)
  ) <> (
    SELECT pg_catalog.count(DISTINCT value->>'location_key')
    FROM jsonb_array_elements(p_scenes)
  ) THEN
    RAISE EXCEPTION 'scene_metadata_duplicate_location_key' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('poyozz-encounter-scene-catalog', 0)
  );

  FOR v_scene IN SELECT value FROM jsonb_array_elements(p_scenes)
  LOOP
    IF jsonb_typeof(v_scene) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'scene_metadata_shape_invalid' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(v_scene)) <> 8 THEN
      RAISE EXCEPTION 'scene_metadata_shape_invalid' USING ERRCODE = '22023';
    END IF;

    v_key := pg_catalog.btrim(COALESCE(v_scene->>'location_key', ''));
    v_name := pg_catalog.btrim(COALESCE(v_scene->>'display_name', ''));
    v_icon := pg_catalog.btrim(COALESCE(v_scene->>'icon', ''));
    v_heading := pg_catalog.btrim(COALESCE(v_scene->>'heading', ''));
    v_description := pg_catalog.btrim(COALESCE(v_scene->>'description', ''));
    v_event_label := pg_catalog.btrim(COALESCE(v_scene->>'event_label', ''));
    v_event_title := pg_catalog.btrim(COALESCE(v_scene->>'event_title', ''));
    v_event_description := pg_catalog.btrim(COALESCE(v_scene->>'event_description', ''));

    IF COALESCE(v_key, '') NOT IN (
      'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
      'department-store', 'bookstore', 'cafe', 'park', 'shopping-street',
      'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema',
      'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery',
      'community-center', 'music-studio', 'bakery', 'coworking-space'
    )
       OR pg_catalog.char_length(v_name) NOT BETWEEN 1 AND 32
       OR pg_catalog.char_length(v_icon) NOT BETWEEN 1 AND 4
       OR v_icon ~ '[<>]'
       OR pg_catalog.char_length(v_heading) NOT BETWEEN 2 AND 50
       OR pg_catalog.char_length(v_description) NOT BETWEEN 30 AND 500
       OR pg_catalog.char_length(v_event_label) NOT BETWEEN 2 AND 20
       OR pg_catalog.char_length(v_event_title) NOT BETWEEN 2 AND 80
       OR pg_catalog.char_length(v_event_description) NOT BETWEEN 2 AND 160 THEN
      RAISE EXCEPTION 'scene_metadata_value_invalid' USING ERRCODE = '22023';
    END IF;

    v_dynamic := v_key IN (
      'shopping-street', 'night-market', 'restaurant', 'university', 'hospital',
      'gym', 'cinema', 'museum', 'hotel', 'train-station', 'library', 'theater',
      'art-gallery', 'community-center', 'music-studio', 'bakery', 'coworking-space'
    );

    IF v_dynamic THEN
      SELECT pg_catalog.count(DISTINCT c.id)::integer INTO v_count
      FROM public.character_schedules s
      JOIN public.characters c ON c.id = s.character_id
      WHERE s.location_key = v_key
        AND s.is_active IS TRUE
        AND s.source_type IN ('manual', 'ai')
        AND s.special_event_key IS NULL
        AND c.visibility = 'public'
        AND c.review_status = 'approved'
        AND c.rights_confirmed IS TRUE
        AND c.deleted_at IS NULL;
      IF COALESCE(v_count, 0) < 2 THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      SELECT pg_catalog.count(*)::integer INTO v_visible_dynamic_count
      FROM public.encounter_scene_registry r
      WHERE r.is_dynamic IS TRUE
        AND r.is_active IS TRUE
        AND (
          SELECT pg_catalog.count(DISTINCT c.id)
          FROM public.character_schedules s
          JOIN public.characters c ON c.id = s.character_id
          WHERE s.location_key = r.location_key
            AND s.is_active IS TRUE
            AND s.source_type IN ('manual', 'ai')
            AND s.special_event_key IS NULL
            AND c.visibility = 'public'
            AND c.review_status = 'approved'
            AND c.rights_confirmed IS TRUE
            AND c.deleted_at IS NULL
        ) >= r.minimum_character_count;
      IF COALESCE(v_visible_dynamic_count, 0) >= 3
         AND NOT EXISTS (
           SELECT 1 FROM public.encounter_scene_registry existing_scene
           WHERE existing_scene.location_key = v_key
             AND existing_scene.is_dynamic IS TRUE
             AND existing_scene.is_active IS TRUE
         ) THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      CASE v_key
        WHEN 'shopping-street' THEN v_x := 1230; v_y := 620;
        WHEN 'night-market' THEN v_x := 390; v_y := 150;
        WHEN 'restaurant' THEN v_x := 550; v_y := 150;
        WHEN 'university' THEN v_x := 710; v_y := 150;
        WHEN 'hospital' THEN v_x := 870; v_y := 150;
        WHEN 'gym' THEN v_x := 1030; v_y := 150;
        WHEN 'cinema' THEN v_x := 1190; v_y := 230;
        WHEN 'museum' THEN v_x := 1430; v_y := 230;
        WHEN 'hotel' THEN v_x := 150; v_y := 310;
        WHEN 'train-station' THEN v_x := 310; v_y := 310;
        WHEN 'library' THEN v_x := 470; v_y := 310;
        WHEN 'theater' THEN v_x := 1190; v_y := 390;
        WHEN 'art-gallery' THEN v_x := 1350; v_y := 390;
        WHEN 'community-center' THEN v_x := 150; v_y := 470;
        WHEN 'music-studio' THEN v_x := 310; v_y := 470;
        WHEN 'bakery' THEN v_x := 470; v_y := 470;
        WHEN 'coworking-space' THEN v_x := 1030; v_y := 470;
        ELSE
          v_skipped := v_skipped + 1;
          CONTINUE;
      END CASE;
    ELSE
      CASE v_key
        WHEN 'airport' THEN v_x := 220; v_y := 140;
        WHEN 'commercial' THEN v_x := 1305; v_y := 94;
        WHEN 'night-bar' THEN v_x := 632; v_y := 294;
        WHEN 'live-house' THEN v_x := 868; v_y := 416;
        WHEN 'apartment' THEN v_x := 666; v_y := 440;
        WHEN 'department-store' THEN v_x := 1020; v_y := 300;
        WHEN 'bookstore' THEN v_x := 480; v_y := 733;
        WHEN 'cafe' THEN v_x := 645; v_y := 624;
        WHEN 'park' THEN v_x := 750; v_y := 766;
        ELSE
          v_skipped := v_skipped + 1;
          CONTINUE;
      END CASE;
      v_count := 0;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.encounter_scene_registry r
      WHERE r.is_active IS TRUE
        AND r.location_key <> v_key
        AND pg_catalog.sqrt(
          pg_catalog.power(r.marker_x - v_x, 2) +
          pg_catalog.power(r.marker_y - v_y, 2)
        ) < 120
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    INSERT INTO public.encounter_scene_registry (
      location_key, display_name, icon, marker_x, marker_y,
      heading, description, event_label, event_title, event_description,
      is_dynamic, minimum_character_count, display_order, is_active
    ) VALUES (
      v_key, v_name, v_icon, v_x, v_y, v_heading, v_description,
      v_event_label, v_event_title, v_event_description,
      v_dynamic, CASE WHEN v_dynamic THEN 2 ELSE 1 END,
      CASE WHEN v_dynamic THEN 10 ELSE 100 END, true
    )
    ON CONFLICT (location_key) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        icon = EXCLUDED.icon,
        heading = EXCLUDED.heading,
        description = EXCLUDED.description,
        event_label = EXCLUDED.event_label,
        event_title = EXCLUDED.event_title,
        event_description = EXCLUDED.event_description,
        is_dynamic = EXCLUDED.is_dynamic,
        minimum_character_count = EXCLUDED.minimum_character_count,
        display_order = EXCLUDED.display_order,
        is_active = true,
        updated_at = pg_catalog.clock_timestamp();
    v_published := v_published + 1;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'published_scene_count', v_published,
    'skipped_scene_count', v_skipped
  );
END;
$$;

REVOKE ALL ON FUNCTION public.publish_encounter_scene_metadata(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_encounter_scene_metadata(jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.get_encounter_dynamic_scene_usage()
RETURNS TABLE(location_key text, character_id uuid, source_type text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT s.location_key, c.id, s.source_type
  FROM public.character_schedules s
  JOIN public.characters c ON c.id = s.character_id
  WHERE s.location_key = ANY(ARRAY[
    'shopping-street', 'night-market', 'restaurant', 'university', 'hospital',
    'gym', 'cinema', 'museum', 'hotel', 'train-station', 'library', 'theater',
    'art-gallery', 'community-center', 'music-studio', 'bakery', 'coworking-space'
  ]::text[])
    AND s.is_active IS TRUE
    AND s.source_type IN ('manual', 'ai')
    AND s.special_event_key IS NULL
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND c.deleted_at IS NULL
;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_dynamic_scene_usage() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_encounter_dynamic_scene_usage() TO service_role;

CREATE OR REPLACE FUNCTION public.get_encounter_scene_catalog()
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
  is_dynamic boolean,
  character_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH scene_counts AS (
    SELECT
      r.location_key, r.display_name, r.icon, r.marker_x, r.marker_y,
      r.heading, r.description, r.event_label, r.event_title,
      r.event_description, r.is_dynamic, r.minimum_character_count,
      r.display_order,
      pg_catalog.count(DISTINCT c.id) AS character_count
    FROM public.encounter_scene_registry r
    LEFT JOIN public.character_schedules s
      ON s.location_key = r.location_key
     AND s.is_active IS TRUE
     AND s.source_type IN ('manual', 'ai')
     AND s.special_event_key IS NULL
    LEFT JOIN public.characters c
      ON c.id = s.character_id
     AND c.visibility = 'public'
     AND c.review_status = 'approved'
     AND c.rights_confirmed IS TRUE
     AND c.deleted_at IS NULL
     AND (c.is_nsfw IS NOT TRUE OR (auth.uid() IS NOT NULL AND private.current_user_is_adult()))
    WHERE r.is_active IS TRUE
    GROUP BY
      r.location_key, r.display_name, r.icon, r.marker_x, r.marker_y,
      r.heading, r.description, r.event_label, r.event_title,
      r.event_description, r.is_dynamic, r.minimum_character_count,
      r.display_order
  ),
  eligible AS (
    SELECT *,
      pg_catalog.row_number() OVER (
        PARTITION BY is_dynamic
        ORDER BY display_order, character_count DESC, location_key
      ) AS scene_rank
    FROM scene_counts
    WHERE is_dynamic IS FALSE OR character_count >= minimum_character_count
  )
  SELECT
    location_key, display_name, icon, marker_x, marker_y, heading,
    description, event_label, event_title, event_description,
    is_dynamic, character_count
  FROM eligible
  WHERE is_dynamic IS FALSE OR scene_rank <= 3
  ORDER BY is_dynamic, display_order, location_key;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_scene_catalog() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_scene_catalog() TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.enqueue_encounter_schedule_generation_test_batch(integer) IS
  'Preview/manual-only enqueue helper. Includes every approved public rights-confirmed non-deleted character regardless of NSFW rating or setting era. The Edge Function must enforce test mode and account allowlist.';
COMMENT ON FUNCTION public.get_encounter_scene_catalog() IS
  'Returns active public Encounter scenes; character counts include NSFW characters only for authenticated users verified as adults.';
