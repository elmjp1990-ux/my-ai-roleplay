-- Persist the group Story clock as in-world state, never derived from device time.
ALTER TABLE public.chat_groups
  ADD COLUMN IF NOT EXISTS story_time text,
  ADD COLUMN IF NOT EXISTS story_location text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.chat_groups'::regclass
      AND conname='chat_groups_story_time_length_check'
  ) THEN
    ALTER TABLE public.chat_groups
      ADD CONSTRAINT chat_groups_story_time_length_check
      CHECK (story_time IS NULL OR char_length(story_time) <= 80);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.chat_groups'::regclass
      AND conname='chat_groups_story_location_length_check'
  ) THEN
    ALTER TABLE public.chat_groups
      ADD CONSTRAINT chat_groups_story_location_length_check
      CHECK (story_location IS NULL OR char_length(story_location) <= 120);
  END IF;
END
$$;

COMMENT ON COLUMN public.chat_groups.story_time IS
  'In-world Story clock updated by the group director AI; never sourced from device or server wall time.';
COMMENT ON COLUMN public.chat_groups.story_location IS
  'In-world Story location shared by all character phones in this group.';

-- Enforce the same 1000-character initial scene limit at the authoritative RPC.
CREATE OR REPLACE FUNCTION public.create_chat_group(
  p_name text,
  p_world_background text,
  p_scene_mode text,
  p_scenes jsonb,
  p_members jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_group_id uuid;
  v_scene jsonb;
  v_member jsonb;
  v_character_id uuid;
  v_scene_id uuid;
  v_position smallint := 0;
  v_member_count integer;
  v_character public.characters%ROWTYPE;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.account_deletion_requests r WHERE r.user_id = v_user_id) THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;
  IF p_name IS NULL OR char_length(btrim(p_name)) NOT BETWEEN 1 AND 80 THEN
    RAISE EXCEPTION 'invalid_group_name' USING ERRCODE = '22023';
  END IF;
  IF p_world_background IS NULL OR char_length(p_world_background) > 10000 THEN
    RAISE EXCEPTION 'invalid_world_background' USING ERRCODE = '22023';
  END IF;
  IF p_scene_mode IS DISTINCT FROM 'shared' THEN
    RAISE EXCEPTION 'group_scene_mode_must_be_shared' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_members) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'members_must_be_array' USING ERRCODE = '22023';
  END IF;
  v_member_count := jsonb_array_length(p_members);
  IF v_member_count NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'group_requires_one_to_three_characters' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_scenes) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'invalid_scenes' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_scenes) <> 1 THEN
    RAISE EXCEPTION 'shared_mode_requires_one_scene' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.chat_groups(owner_id, name, world_background, scene_mode)
  VALUES (v_user_id, btrim(p_name), p_world_background, 'shared')
  RETURNING id INTO v_group_id;

  v_scene := p_scenes->0;
  IF jsonb_typeof(v_scene) IS DISTINCT FROM 'object'
     OR jsonb_typeof(v_scene->'name') IS DISTINCT FROM 'string'
     OR (v_scene ? 'description' AND jsonb_typeof(v_scene->'description') IS DISTINCT FROM 'string')
     OR char_length(btrim(COALESCE(v_scene->>'name',''))) NOT BETWEEN 1 AND 80
     OR char_length(COALESCE(v_scene->>'description','')) > 1000 THEN
    RAISE EXCEPTION 'invalid_scene_payload' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.chat_group_scenes(group_id, name, description, position)
  VALUES (v_group_id, btrim(v_scene->>'name'), COALESCE(v_scene->>'description',''), 1)
  RETURNING id INTO v_scene_id;

  FOR v_member IN SELECT value FROM jsonb_array_elements(p_members)
  LOOP
    v_position := v_position + 1;
    IF jsonb_typeof(v_member) IS DISTINCT FROM 'object'
       OR jsonb_typeof(v_member->'character_id') IS DISTINCT FROM 'string'
       OR NULLIF(v_member->>'character_id', '') IS NULL THEN
      RAISE EXCEPTION 'invalid_member_payload' USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_character_id := (v_member->>'character_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'invalid_character_id' USING ERRCODE = '22023';
    END;

    -- A character can join a group whenever it is public and not taken down.
    -- review_status is intentionally not an access gate: there is no pre-publication review workflow.
    SELECT c.* INTO v_character
    FROM public.characters c
    WHERE c.id = v_character_id
      AND c.deleted_at IS NULL
      AND c.visibility = 'public'
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'character_not_public_or_unavailable' USING ERRCODE = '42501';
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.chat_group_members m
      WHERE m.group_id = v_group_id AND m.character_id = v_character_id
    ) THEN
      RAISE EXCEPTION 'duplicate_character' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.chat_group_members(group_id, character_id, position, scene_id, character_snapshot)
    VALUES (
      v_group_id, v_character_id, v_position, v_scene_id,
      jsonb_build_object(
        'id', v_character.id, 'name', v_character.name, 'gender', v_character.gender,
        'age', v_character.age, 'intro', v_character.intro,
        'opening', COALESCE((
          SELECT cs.opening_message FROM public.character_stories cs
          WHERE cs.character_id = v_character.id
            AND cs.visibility = 'public'
          ORDER BY cs.created_at ASC LIMIT 1
        ), ''),
        'race', v_character.race, 'style', v_character.style, 'tags', v_character.tags
      )
    );
  END LOOP;
  RETURN v_group_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_chat_group(text,text,text,jsonb,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_chat_group(text,text,text,jsonb,jsonb) TO authenticated, service_role;


-- Return tags that are still used by active public characters or the current user's
-- active private/public characters. Exclude the card being edited so its last-used
-- tag disappears immediately when the creator removes it.
CREATE OR REPLACE FUNCTION public.get_active_character_tags(
  p_exclude_character_id uuid DEFAULT NULL
)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT COALESCE(
    array_agg(DISTINCT btrim(tag.value) ORDER BY btrim(tag.value)),
    ARRAY[]::text[]
  )
  FROM public.characters c
  CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE
      WHEN jsonb_typeof(c.tags) = 'array' THEN c.tags
      ELSE '[]'::jsonb
    END
  ) AS tag(value)
  WHERE c.deleted_at IS NULL
    AND c.id IS DISTINCT FROM p_exclude_character_id
    AND (c.author_id = auth.uid() OR c.visibility = 'public')
    AND btrim(tag.value) <> '';
$function$;

REVOKE ALL ON FUNCTION public.get_active_character_tags(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_active_character_tags(uuid) TO authenticated;
COMMENT ON FUNCTION public.get_active_character_tags(uuid) IS
  'Returns distinct tags still used by active public characters and the caller''s own active characters, excluding the currently edited card.';
