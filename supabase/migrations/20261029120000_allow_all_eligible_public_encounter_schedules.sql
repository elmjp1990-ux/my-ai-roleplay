-- The latest_eligible flag is a 24-hour "latest character" promotion window,
-- not a general publication eligibility flag. Do not hide older public characters
-- from city encounters merely because that window has elapsed.
CREATE OR REPLACE FUNCTION public.get_encounter_character_schedule(p_character_id uuid)
RETURNS TABLE (
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
    s.weekday, s.day_type, s.start_time, s.end_time,
    s.location_key, s.activity, s.priority
  FROM public.characters c
  JOIN public.character_schedules s ON s.character_id = c.id
  WHERE c.id = p_character_id
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
  ORDER BY s.priority DESC, s.weekday NULLS FIRST, s.start_time;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_character_schedule(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_character_schedule(uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.get_encounter_character_schedule(uuid) IS
  'Returns active schedules for public, non-deleted, approved, rights-confirmed characters. latest_eligible is intentionally not required because it is only a 24-hour latest-character promotion flag. NSFW schedules require an authenticated adult. Direct schedule table access remains author-only.';
