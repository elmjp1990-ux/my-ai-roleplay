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

-- Enforce the opening limit at the data boundary. NOT VALID avoids blocking
-- existing legacy scenes while the constraint still applies to every new write.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.chat_group_scenes'::regclass
      AND conname='chat_group_scenes_description_max_1000'
  ) THEN
    ALTER TABLE public.chat_group_scenes
      ADD CONSTRAINT chat_group_scenes_description_max_1000
      CHECK (description IS NULL OR char_length(description) <= 1000) NOT VALID;
  END IF;
END
$$;
COMMENT ON CONSTRAINT chat_group_scenes_description_max_1000 ON public.chat_group_scenes IS
  'New group opening scenes are limited to 1000 characters; existing legacy rows are not retroactively rejected.';




-- Return tags that are still used by active public characters or the current user's
-- active private/public characters. Exclude the card being edited so its last-used
-- tag disappears immediately when the creator removes it.
CREATE OR REPLACE FUNCTION public.get_active_character_tags(
  p_exclude_character_id uuid DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_tags text[];
BEGIN
  -- Dynamic SQL keeps this additive migration compatible with isolated test
  -- fixtures that create public.characters later in the same workflow.
  EXECUTE $query$
    SELECT COALESCE(
      array_agg(DISTINCT btrim(tag.value) ORDER BY btrim(tag.value)),
      ARRAY[]::text[]
    )
    FROM public.characters c
    CROSS JOIN LATERAL jsonb_array_elements_text(
      CASE
        WHEN jsonb_typeof(to_jsonb(c.tags)) = 'array' THEN to_jsonb(c.tags)
        ELSE '[]'::jsonb
      END
    ) AS tag(value)
    WHERE c.deleted_at IS NULL
      AND c.id IS DISTINCT FROM $1
      AND (c.author_id = $2 OR c.visibility = 'public')
      AND btrim(tag.value) <> ''
  $query$
  INTO v_tags
  USING p_exclude_character_id, auth.uid();
  RETURN COALESCE(v_tags, ARRAY[]::text[]);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_active_character_tags(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_active_character_tags(uuid) TO authenticated;
COMMENT ON FUNCTION public.get_active_character_tags(uuid) IS
  'Returns distinct tags still used by active public characters and the caller''s own active characters, excluding the currently edited card.';
