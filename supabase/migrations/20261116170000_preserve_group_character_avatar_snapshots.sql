-- Preserve a stable portrait source in each new group member snapshot.
-- Keep the existing group-creation eligibility and validation rules unchanged.
-- A soft-deleted character remains available to its existing chats, but is offline.

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
  v_scene_id uuid;
  v_position smallint := 0;
  v_member_count integer;
  v_character public.characters%ROWTYPE;
  v_primary_illustration_path text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests r WHERE r.user_id = v_user_id
  ) THEN
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
     OR char_length(COALESCE(v_scene->>'description','')) > 5000 THEN
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

    -- Preserve the deployed rule: only public, non-deleted characters can join.
    -- review_status is intentionally not an access gate in the current product.
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
            AND cs.visibility = 'public'
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

-- Mark existing chat snapshots offline when their character is soft-deleted.
-- Only the deletedAt metadata is changed; portrait, intro, opening and story data
-- remain untouched. Keep chat_sessions.updated_at stable to avoid invalidating
-- the player's optimistic chat-sync version.
CREATE OR REPLACE FUNCTION private.mark_character_chat_snapshots_offline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    UPDATE public.chat_sessions cs
    SET character_snapshot = jsonb_set(
      COALESCE(cs.character_snapshot, '{}'::jsonb),
      '{deletedAt}',
      to_jsonb(NEW.deleted_at),
      true
    )
    WHERE cs.character_id = NEW.id
      AND cs.deleted_at IS NULL
      AND cs.character_snapshot->>'deletedAt' IS DISTINCT FROM NEW.deleted_at::text
      AND NOT EXISTS (
        SELECT 1
        FROM public.account_deletion_requests r
        WHERE r.user_id = cs.user_id
      );

    UPDATE public.chat_group_members gm
    SET character_snapshot = jsonb_set(
      COALESCE(gm.character_snapshot, '{}'::jsonb),
      '{deletedAt}',
      to_jsonb(NEW.deleted_at),
      true
    )
    FROM public.chat_groups g
    WHERE gm.group_id = g.id
      AND gm.character_id = NEW.id
      AND g.deleted_at IS NULL
      AND gm.character_snapshot->>'deletedAt' IS DISTINCT FROM NEW.deleted_at::text
      AND NOT EXISTS (
        SELECT 1
        FROM public.account_deletion_requests r
        WHERE r.user_id = g.owner_id
      );
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.mark_character_chat_snapshots_offline() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS characters_mark_existing_chat_snapshots_offline ON public.characters;
CREATE TRIGGER characters_mark_existing_chat_snapshots_offline
AFTER UPDATE OF deleted_at ON public.characters
FOR EACH ROW
WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
EXECUTE FUNCTION private.mark_character_chat_snapshots_offline();
