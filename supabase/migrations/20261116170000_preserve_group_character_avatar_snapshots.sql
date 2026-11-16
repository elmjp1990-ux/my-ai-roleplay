-- Preserve a stable portrait source in each new group member snapshot.
-- This keeps existing group chats visually intact after a character is soft-deleted,
-- without making deleted characters visible to public discovery or new chat creation.

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
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_group_id uuid;
  v_scene jsonb;
  v_member jsonb;
  v_character_id uuid;
  v_scene_position smallint;
  v_scene_id uuid;
  v_position smallint := 0;
  v_member_count integer;
  v_scene_count integer;
  v_character public.characters%ROWTYPE;
  v_primary_illustration_path text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF p_name IS NULL OR char_length(btrim(p_name)) NOT BETWEEN 1 AND 80 THEN
    RAISE EXCEPTION 'invalid_group_name' USING ERRCODE = '22023';
  END IF;
  IF p_world_background IS NULL OR char_length(p_world_background) > 10000 THEN
    RAISE EXCEPTION 'invalid_world_background' USING ERRCODE = '22023';
  END IF;
  IF p_scene_mode IS NULL OR p_scene_mode NOT IN ('shared', 'separate') THEN
    RAISE EXCEPTION 'invalid_scene_mode' USING ERRCODE = '22023';
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
  v_scene_count := jsonb_array_length(p_scenes);
  IF v_scene_count NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'invalid_scenes' USING ERRCODE = '22023';
  END IF;
  IF p_scene_mode = 'shared' AND v_scene_count <> 1 THEN
    RAISE EXCEPTION 'shared_mode_requires_one_scene' USING ERRCODE = '22023';
  END IF;
  IF p_scene_mode = 'separate' AND v_scene_count <> v_member_count THEN
    RAISE EXCEPTION 'separate_mode_requires_one_scene_per_character' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.chat_groups(owner_id, name, world_background, scene_mode)
  VALUES (v_user_id, btrim(p_name), p_world_background, p_scene_mode)
  RETURNING id INTO v_group_id;

  FOR v_scene IN SELECT value FROM jsonb_array_elements(p_scenes)
  LOOP
    v_position := v_position + 1;
    IF jsonb_typeof(v_scene) IS DISTINCT FROM 'object'
      OR jsonb_typeof(v_scene->'name') IS DISTINCT FROM 'string'
      OR (v_scene ? 'description' AND jsonb_typeof(v_scene->'description') IS DISTINCT FROM 'string')
      OR char_length(btrim(COALESCE(v_scene->>'name',''))) NOT BETWEEN 1 AND 80
      OR char_length(COALESCE(v_scene->>'description','')) > 5000 THEN
      RAISE EXCEPTION 'invalid_scene_payload' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.chat_group_scenes(group_id, name, description, position)
    VALUES (v_group_id, btrim(v_scene->>'name'), COALESCE(v_scene->>'description',''), v_position);
  END LOOP;

  v_position := 0;
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

    SELECT c.* INTO v_character
    FROM public.characters c
    WHERE c.id = v_character_id
      AND c.deleted_at IS NULL
      AND (c.author_id = v_user_id OR (c.visibility = 'public' AND c.review_status = 'approved'))
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'character_not_accessible' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.chat_group_members m
      WHERE m.group_id = v_group_id AND m.character_id = v_character_id
    ) THEN
      RAISE EXCEPTION 'duplicate_character' USING ERRCODE = '22023';
    END IF;

    IF p_scene_mode = 'shared' THEN
      v_scene_position := 1;
    ELSE
      BEGIN
        v_scene_position := (v_member->>'scene_position')::smallint;
      EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'invalid_scene_position' USING ERRCODE = '22023';
      END;
      IF v_scene_position IS DISTINCT FROM v_position
        OR v_scene_position NOT BETWEEN 1 AND v_scene_count THEN
        RAISE EXCEPTION 'invalid_scene_position' USING ERRCODE = '22023';
      END IF;
    END IF;

    SELECT id INTO v_scene_id
    FROM public.chat_group_scenes
    WHERE group_id = v_group_id AND position = v_scene_position;

    SELECT ci.storage_path INTO v_primary_illustration_path
    FROM public.character_illustrations ci
    WHERE ci.character_id = v_character.id
      AND ci.asset_type = 'primary'
    ORDER BY ci.sort_order ASC, ci.created_at ASC, ci.id ASC
    LIMIT 1;

    INSERT INTO public.chat_group_members(
      group_id, character_id, position, scene_id, character_snapshot
    ) VALUES (
      v_group_id, v_character_id, v_position, v_scene_id,
      jsonb_build_object(
        'id', v_character.id,
        'name', v_character.name,
        'gender', v_character.gender,
        'age', v_character.age,
        'intro', v_character.intro,
        'image', CASE WHEN v_primary_illustration_path IS NOT NULL THEN '' ELSE COALESCE(v_character.avatar_url, '') END,
        'imagePath', COALESCE(v_primary_illustration_path, ''),
        'opening', COALESCE((
          SELECT cs.opening_message
          FROM public.character_stories cs
          WHERE cs.character_id = v_character.id
            AND (v_character.author_id = v_user_id OR cs.visibility = 'public')
          ORDER BY cs.created_at ASC
          LIMIT 1
        ), ''),
        'race', v_character.race,
        'style', v_character.style,
        'tags', v_character.tags
      )
    );
  END LOOP;

  RETURN v_group_id;
END;
$$;
