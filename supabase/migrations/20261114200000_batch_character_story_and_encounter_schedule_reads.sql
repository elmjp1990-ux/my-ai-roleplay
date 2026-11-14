-- Bound public encounter schedule hydration to one RPC per 10-character page.
-- Return only the newest story row per character for the owner's 10-row character page.

CREATE OR REPLACE FUNCTION public.get_latest_owned_character_stories(p_character_ids uuid[])
RETURNS TABLE (
  character_id uuid,
  opening_message text,
  visibility text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT DISTINCT ON (s.character_id)
    s.character_id,
    s.opening_message,
    s.visibility,
    s.created_at
  FROM public.character_stories s
  JOIN public.characters c ON c.id = s.character_id
  WHERE p_character_ids IS NOT NULL
    AND pg_catalog.cardinality(p_character_ids) BETWEEN 1 AND 10
    AND s.character_id = ANY (p_character_ids)
    AND c.author_id = (SELECT auth.uid())
  ORDER BY s.character_id, s.created_at DESC, s.id DESC;
$$;

REVOKE ALL ON FUNCTION public.get_latest_owned_character_stories(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_latest_owned_character_stories(uuid[]) TO authenticated;

COMMENT ON FUNCTION public.get_latest_owned_character_stories(uuid[]) IS
  'Returns at most one newest story row per supplied character ID, limited to 10 IDs and the authenticated character owner. Uses invoker privileges and existing table RLS.';

CREATE OR REPLACE FUNCTION public.get_encounter_character_schedules(p_character_ids uuid[])
RETURNS TABLE (
  character_id uuid,
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
  priority smallint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    s.character_id,
    s.weekday,
    s.day_type,
    s.start_time,
    s.end_time,
    s.location_key,
    s.activity,
    s.priority
  FROM public.characters c
  JOIN public.character_schedules s ON s.character_id = c.id
  WHERE p_character_ids IS NOT NULL
    AND pg_catalog.cardinality(p_character_ids) BETWEEN 1 AND 10
    AND c.id = ANY (p_character_ids)
    AND c.visibility = 'public'
    AND c.deleted_at IS NULL
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND s.is_active IS TRUE
    AND (
      c.is_nsfw IS NOT TRUE
      OR (
        (SELECT auth.uid()) IS NOT NULL
        AND private.current_user_is_adult()
      )
    )
  ORDER BY s.character_id, s.priority DESC, s.weekday NULLS FIRST, s.start_time;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_character_schedules(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_character_schedules(uuid[]) TO anon, authenticated;

COMMENT ON FUNCTION public.get_encounter_character_schedules(uuid[]) IS
  'Batch counterpart to get_encounter_character_schedule. Returns active schedules only for public, non-deleted, approved, rights-confirmed characters; accepts at most 10 IDs and preserves the existing NSFW adult gate.';
