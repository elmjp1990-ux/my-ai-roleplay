BEGIN;

-- Preserve the AI's natural-language place and arrival scene independently
-- from the system-owned map key. Unknown places remain stored as intent.
ALTER TABLE public.character_schedules
  ADD COLUMN IF NOT EXISTS location_description text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS scene_description text NOT NULL DEFAULT '';

ALTER TABLE public.character_schedules
  ALTER COLUMN location_key DROP NOT NULL;

ALTER TABLE public.encounter_schedule_weather_decisions
  ADD COLUMN IF NOT EXISTS scene_description text NOT NULL DEFAULT '';

ALTER TABLE public.encounter_scene_registry
  ADD COLUMN IF NOT EXISTS aliases text[] NOT NULL DEFAULT '{}';

UPDATE public.encounter_scene_registry
SET aliases = CASE location_key
  WHEN 'airport' THEN ARRAY['機場', '國際機場']
  WHEN 'commercial' THEN ARRAY['公司', '辦公室', '商辦', '辦公大樓', '企業大樓', '商業大樓']
  WHEN 'night-bar' THEN ARRAY['酒吧', '酒館', '夜店']
  WHEN 'live-house' THEN ARRAY['Live House', 'livehouse', '現場音樂', '音樂展演']
  WHEN 'apartment' THEN ARRAY['住家', '公寓', '住宅']
  WHEN 'department-store' THEN ARRAY['百貨', '百貨公司']
  WHEN 'bookstore' THEN ARRAY['書店']
  WHEN 'cafe' THEN ARRAY['咖啡廳', '咖啡店']
  WHEN 'park' THEN ARRAY['公園']
  WHEN 'shopping-street' THEN ARRAY['購物街', '商店街', '逛街商圈']
  WHEN 'night-market' THEN ARRAY['夜市', '夜間市集']
  WHEN 'restaurant' THEN ARRAY['餐廳', '餐館', '飯店餐廳']
  WHEN 'university' THEN ARRAY['大學', '學校', '校園']
  WHEN 'hospital' THEN ARRAY['醫院', '診所']
  WHEN 'gym' THEN ARRAY['健身房', '健身中心']
  WHEN 'cinema' THEN ARRAY['電影院', '影城']
  WHEN 'museum' THEN ARRAY['博物館', '美術館', '展覽館']
  WHEN 'hotel' THEN ARRAY['飯店', '旅館']
  WHEN 'train-station' THEN ARRAY['車站', '火車站', '捷運站', '高鐵站']
  WHEN 'library' THEN ARRAY['圖書館']
  WHEN 'theater' THEN ARRAY['劇院', '劇場']
  WHEN 'art-gallery' THEN ARRAY['藝廊', '畫廊']
  WHEN 'community-center' THEN ARRAY['社區中心', '活動中心']
  WHEN 'music-studio' THEN ARRAY['音樂工作室', '錄音室']
  WHEN 'bakery' THEN ARRAY['麵包店', '烘焙坊']
  WHEN 'coworking-space' THEN ARRAY['共享辦公室', '共同工作空間']
  ELSE aliases
END,
updated_at = pg_catalog.clock_timestamp()
WHERE location_key IN (
  'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
  'department-store', 'bookstore', 'cafe', 'park', 'shopping-street',
  'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema',
  'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery',
  'community-center', 'music-studio', 'bakery', 'coworking-space'
);

CREATE OR REPLACE FUNCTION public.resolve_encounter_scene_location_key(p_location_description text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT r.location_key
  FROM public.encounter_scene_registry r
  WHERE pg_catalog.lower(pg_catalog.btrim(r.display_name)) =
        pg_catalog.lower(pg_catalog.btrim(COALESCE(p_location_description, '')))
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.unnest(r.aliases) AS alias(value)
       WHERE pg_catalog.lower(pg_catalog.btrim(alias.value)) =
             pg_catalog.lower(pg_catalog.btrim(COALESCE(p_location_description, '')))
     )
  ORDER BY r.is_dynamic, r.display_order, r.location_key
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.resolve_encounter_scene_location_key(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_encounter_scene_location_key(text)
  TO service_role;

-- Count schedules by their system-resolved key, including previously unmatched
-- natural-language places when an alias is added later.
DO $catalog$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_encounter_scene_catalog()'::regprocedure
  ) INTO v_definition;

  v_old := 'ON s.location_key = r.location_key';
  v_new := 'ON COALESCE(s.location_key, public.resolve_encounter_scene_location_key(s.location_description)) = r.location_key';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'scene_catalog_schedule_join_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$catalog$;

-- The publisher keeps the original natural-language intent even when the
-- system cannot currently map it to a scene key.
DO $publisher$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.publish_encounter_schedule_batch(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_definition;

  v_old := $old$OR COALESCE(v_slot->>'location_key', '') NOT IN (
               'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
               'department-store', 'bookstore', 'cafe', 'park', 'shopping-street',
               'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema',
               'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery',
               'community-center', 'music-studio', 'bakery', 'coworking-space'
             )
             OR char_length(COALESCE(v_slot->>'activity', '')) NOT BETWEEN 1 AND 200$old$;
  v_new := $new$OR (
               NULLIF(v_slot->>'location_key', '') IS NOT NULL
               AND NULLIF(v_slot->>'location_key', '') NOT IN (
                 'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
                 'department-store', 'bookstore', 'cafe', 'park', 'shopping-street',
                 'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema',
                 'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery',
                 'community-center', 'music-studio', 'bakery', 'coworking-space'
               )
             )
             OR char_length(COALESCE(v_slot->>'location_description', '')) NOT BETWEEN 1 AND 120
             OR char_length(COALESCE(v_slot->>'scene_description', '')) NOT BETWEEN 8 AND 500
             OR char_length(COALESCE(v_slot->>'activity', '')) NOT BETWEEN 1 AND 200$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'daily_location_validation_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$OR COALESCE(v_special_slot->>'location_key', '') NOT IN (
             'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
             'department-store', 'bookstore', 'cafe', 'park', 'shopping-street',
             'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema',
             'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery',
             'community-center', 'music-studio', 'bakery', 'coworking-space'
           )
           OR pg_catalog.char_length(COALESCE(v_special_slot->>'activity', '')) NOT BETWEEN 1 AND 200$old$;
  v_new := $new$OR (
             NULLIF(v_special_slot->>'location_key', '') IS NOT NULL
             AND NULLIF(v_special_slot->>'location_key', '') NOT IN (
               'airport', 'commercial', 'night-bar', 'live-house', 'apartment',
               'department-store', 'bookstore', 'cafe', 'park', 'shopping-street',
               'night-market', 'restaurant', 'university', 'hospital', 'gym', 'cinema',
               'museum', 'hotel', 'train-station', 'library', 'theater', 'art-gallery',
               'community-center', 'music-studio', 'bakery', 'coworking-space'
             )
           )
           OR pg_catalog.char_length(COALESCE(v_special_slot->>'location_description', '')) NOT BETWEEN 1 AND 120
           OR pg_catalog.char_length(COALESCE(v_special_slot->>'scene_description', '')) NOT BETWEEN 8 AND 500
           OR pg_catalog.char_length(COALESCE(v_special_slot->>'activity', '')) NOT BETWEEN 1 AND 200$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'special_location_validation_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$location_key, activity,
            priority, is_active, source_type, variant_key, variant_weight,$old$;
  v_new := $new$location_key, location_description, activity, scene_description,
            priority, is_active, source_type, variant_key, variant_weight,$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'daily_insert_columns_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$v_slot->>'location_key', v_slot->>'activity',
            50, true, 'ai',$old$;
  v_new := $new$v_slot->>'location_key', NULLIF(v_slot->>'location_description', ''), v_slot->>'activity',
            v_slot->>'scene_description', 50, true, 'ai',$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'daily_insert_values_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$location_key, activity,
          priority, is_active, source_type, variant_key, variant_weight, special_event_key,$old$;
  v_new := $new$location_key, location_description, activity, scene_description,
          priority, is_active, source_type, variant_key, variant_weight, special_event_key,$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'special_insert_columns_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$v_special_slot->>'location_key', v_special_slot->>'activity',
          60, true, 'ai',$old$;
  v_new := $new$v_special_slot->>'location_key', NULLIF(v_special_slot->>'location_description', ''), v_special_slot->>'activity',
          v_special_slot->>'scene_description', 60, true, 'ai',$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'special_insert_values_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$publisher$;

-- Extend the current schedule resolver to freeze and return the scene description
-- alongside the activity and encounter greeting.
DO $resolver$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.resolve_encounter_character_schedule(uuid,uuid,text,timestamptz)'::regprocedure
  ) INTO v_definition;

  v_old := $old$  activity text,
  priority smallint,$old$;
  v_new := $new$  activity text,
  scene_description text,
  priority smallint,$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'resolver_return_scene_description_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := '  v_effective_activity text;';
  v_new := '  v_effective_activity text;' || pg_catalog.chr(10) || '  v_effective_scene_description text;';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'resolver_scene_description_variable_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$WHERE available_scene.location_key = s.location_key$old$;
  v_new := $new$WHERE available_scene.location_key = COALESCE(
          s.location_key,
          public.resolve_encounter_scene_location_key(s.location_description)
        )$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'resolver_scene_match_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$THEN COALESCE(v_row.rain_fallback_location_key, v_row.location_key)
        ELSE v_row.location_key END;$old$;
  v_new := $new$THEN COALESCE(v_row.rain_fallback_location_key, v_row.location_key,
            public.resolve_encounter_scene_location_key(v_row.location_description))
        ELSE COALESCE(v_row.location_key,
            public.resolve_encounter_scene_location_key(v_row.location_description)) END;$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'resolver_effective_location_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$v_effective_activity := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN COALESCE(v_row.rain_fallback_activity, v_row.activity)
        ELSE v_row.activity END;$old$;
  v_new := $new$v_effective_activity := CASE
        WHEN v_is_raining IS TRUE AND v_row.is_outdoor IS TRUE
          THEN COALESCE(v_row.rain_fallback_activity, v_row.activity)
        ELSE v_row.activity END;
      v_effective_scene_description := v_row.scene_description;$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'resolver_scene_description_assignment_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$location_key, activity,
        encounter_greeting, is_outdoor, decided_weather_text, decided_is_raining$old$;
  v_new := $new$location_key, activity, scene_description,
        encounter_greeting, is_outdoor, decided_weather_text, decided_is_raining$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'resolver_decision_insert_columns_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$v_effective_location, v_effective_activity, v_effective_greeting,$old$;
  v_new := $new$v_effective_location, v_effective_activity, v_effective_scene_description, v_effective_greeting,$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'resolver_decision_insert_values_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$v_decision.activity,
      v_row.priority,$old$;
  v_new := $new$v_decision.activity,
      v_decision.scene_description,
      v_row.priority,$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'resolver_return_scene_description_select_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$resolver$;

-- The public list RPC mirrors the resolver's new output field.
DO $schedule_list$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_encounter_character_schedules(uuid[])'::regprocedure
  ) INTO v_definition;

  v_old := $old$  activity text,
  priority smallint,$old$;
  v_new := $new$  activity text,
  scene_description text,
  priority smallint,$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'schedule_list_return_scene_description_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := $old$    resolved.activity,
    resolved.priority,$old$;
  v_new := $new$    resolved.activity,
    resolved.scene_description,
    resolved.priority,$new$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'schedule_list_select_scene_description_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$schedule_list$;

COMMENT ON COLUMN public.character_schedules.scene_description IS
  'AI-generated character-specific description of the scene after arrival; independent from activity and encounter greeting.';
COMMENT ON COLUMN public.character_schedules.location_description IS
  'Original natural-language place intent. System resolves it to a map scene; unmatched intent is retained for later rematching.';

COMMIT;
