-- Authorization helper used by the trusted Encounter session-creation Edge Function.
-- It evaluates the caller's JWT context so adult eligibility is checked for the actual user.
CREATE OR REPLACE FUNCTION public.can_open_encounter_session(p_character_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.characters c
    WHERE c.id = p_character_id
      AND c.visibility = 'public'
      AND c.deleted_at IS NULL
      AND c.review_status = 'approved'
      AND c.latest_eligible IS TRUE
      AND c.rights_confirmed IS TRUE
      AND (
        c.is_nsfw IS NOT TRUE
        OR (
          auth.uid() IS NOT NULL
          AND private.current_user_is_adult()
        )
      )
  );
$$;

REVOKE ALL ON FUNCTION public.can_open_encounter_session(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_open_encounter_session(uuid) TO authenticated;
COMMENT ON FUNCTION public.can_open_encounter_session(uuid) IS
  'Checks whether the JWT caller may open Encounter mode with this currently eligible public character; NSFW characters require adult verification.';
