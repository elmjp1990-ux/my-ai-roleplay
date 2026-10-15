-- GROUP-01: proposed group-chat schema draft.
-- REVIEW REQUIRED: this file is intentionally in supabase/drafts and is NOT an active migration.
-- Do not execute until reviewed against the live schema and tested in a disposable Supabase project.
-- AI providers and wallet charging are deliberately not called here.

CREATE TABLE IF NOT EXISTS public.chat_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
  world_background text NOT NULL DEFAULT '' CHECK (char_length(world_background) <= 10000),
  scene_mode text NOT NULL CHECK (scene_mode IN ('shared', 'separate')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  archived_at timestamptz
);

CREATE INDEX IF NOT EXISTS chat_groups_owner_updated_idx
  ON public.chat_groups (owner_id, updated_at DESC)
  WHERE archived_at IS NULL;

CREATE TABLE IF NOT EXISTS public.chat_group_scenes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
  description text NOT NULL DEFAULT '' CHECK (char_length(description) <= 5000),
  position smallint NOT NULL CHECK (position BETWEEN 1 AND 3),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (group_id, position),
  UNIQUE (id, group_id)
);

CREATE TABLE IF NOT EXISTS public.chat_group_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE RESTRICT,
  position smallint NOT NULL CHECK (position BETWEEN 1 AND 3),
  scene_id uuid,
  character_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (group_id, character_id),
  UNIQUE (group_id, position),
  FOREIGN KEY (scene_id, group_id)
    REFERENCES public.chat_group_scenes(id, group_id) ON DELETE CASCADE
);

-- Enforce the 3-character cap even when clients race to insert concurrently.
-- Serialize inserts by locking the parent group row. Direct inserts are also
-- constrained by RLS; the trigger is defense in depth, not a substitute for RPC.
CREATE OR REPLACE FUNCTION public.enforce_chat_group_member_limit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $$
DECLARE
  v_count integer;
BEGIN
  PERFORM 1 FROM public.chat_groups WHERE id = NEW.group_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'group_not_found' USING ERRCODE = '23503';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.chat_group_members
  WHERE group_id = NEW.group_id
    AND id IS DISTINCT FROM NEW.id;

  IF v_count >= 3 THEN
    RAISE EXCEPTION 'group_character_limit_exceeded' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_group_member_limit ON public.chat_group_members;
CREATE TRIGGER chat_group_member_limit
BEFORE INSERT OR UPDATE OF group_id ON public.chat_group_members
FOR EACH ROW EXECUTE FUNCTION public.enforce_chat_group_member_limit();

CREATE TABLE IF NOT EXISTS public.chat_group_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  scene_id uuid,
  turn_id uuid NOT NULL,
  sequence_no integer NOT NULL CHECK (sequence_no >= 0),
  speaker_type text NOT NULL CHECK (speaker_type IN ('user', 'character', 'system')),
  character_id uuid REFERENCES public.characters(id) ON DELETE RESTRICT,
  content text NOT NULL CHECK (char_length(content) <= 20000),
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (scene_id, group_id)
    REFERENCES public.chat_group_scenes(id, group_id) ON DELETE RESTRICT,
  UNIQUE (group_id, turn_id, sequence_no),
  CHECK (
    (speaker_type = 'character' AND character_id IS NOT NULL)
    OR (speaker_type <> 'character' AND character_id IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS chat_group_messages_history_idx
  ON public.chat_group_messages (group_id, created_at, sequence_no);

ALTER TABLE public.chat_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_group_scenes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_group_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS chat_groups_owner_select ON public.chat_groups;
CREATE POLICY chat_groups_owner_select ON public.chat_groups
  FOR SELECT TO authenticated USING (owner_id = (SELECT auth.uid()));
DROP POLICY IF EXISTS chat_groups_owner_update ON public.chat_groups;
CREATE POLICY chat_groups_owner_update ON public.chat_groups
  FOR UPDATE TO authenticated USING (owner_id = (SELECT auth.uid()))
  WITH CHECK (owner_id = (SELECT auth.uid()));
DROP POLICY IF EXISTS chat_groups_owner_delete ON public.chat_groups;
CREATE POLICY chat_groups_owner_delete ON public.chat_groups
  FOR DELETE TO authenticated USING (owner_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS chat_group_scenes_owner_access ON public.chat_group_scenes;
CREATE POLICY chat_group_scenes_owner_access ON public.chat_group_scenes
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = group_id AND g.owner_id = (SELECT auth.uid())
  ));

DROP POLICY IF EXISTS chat_group_members_owner_access ON public.chat_group_members;
CREATE POLICY chat_group_members_owner_access ON public.chat_group_members
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = group_id AND g.owner_id = (SELECT auth.uid())
  ));

DROP POLICY IF EXISTS chat_group_messages_owner_access ON public.chat_group_messages;
CREATE POLICY chat_group_messages_owner_access ON public.chat_group_messages
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = group_id AND g.owner_id = (SELECT auth.uid())
  ));

-- Explicit least-privilege grants: creation/writes go through checked RPCs only.
REVOKE ALL ON TABLE public.chat_groups, public.chat_group_scenes,
  public.chat_group_members, public.chat_group_messages FROM anon, authenticated;
GRANT SELECT ON TABLE public.chat_groups, public.chat_group_scenes,
  public.chat_group_members, public.chat_group_messages TO authenticated;
GRANT UPDATE, DELETE ON TABLE public.chat_groups TO authenticated;

-- Create group, scenes, and member snapshots in one transaction.
-- Expected p_members format:
-- [{"character_id":"<uuid>","scene_position":1}, ...]
-- The caller may add only owned characters or approved public characters.
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
  -- Keep type validation separate: jsonb_array_length throws for non-array JSON.
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
      -- In separate-scene mode each member maps to the corresponding unique
      -- scene position, preventing multiple characters from silently sharing one.
      IF v_scene_position IS DISTINCT FROM v_position
        OR v_scene_position NOT BETWEEN 1 AND v_scene_count THEN
        RAISE EXCEPTION 'invalid_scene_position' USING ERRCODE = '22023';
      END IF;
    END IF;

    SELECT id INTO v_scene_id
    FROM public.chat_group_scenes
    WHERE group_id = v_group_id AND position = v_scene_position;

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
        -- Opening text lives in character_stories, not public.characters.
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

REVOKE ALL ON FUNCTION public.create_chat_group(text, text, text, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_chat_group(text, text, text, jsonb, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_chat_group(text, text, text, jsonb, jsonb) TO authenticated;

-- Prevent direct client writes that bypass the transactional creation path.
REVOKE INSERT ON public.chat_groups FROM anon, authenticated;
REVOKE INSERT ON public.chat_group_scenes FROM anon, authenticated;
REVOKE INSERT ON public.chat_group_members FROM anon, authenticated;
REVOKE INSERT ON public.chat_group_messages FROM anon, authenticated;
REVOKE UPDATE, DELETE ON public.chat_group_scenes FROM anon, authenticated;
REVOKE UPDATE, DELETE ON public.chat_group_members FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.chat_group_messages FROM anon, authenticated;
