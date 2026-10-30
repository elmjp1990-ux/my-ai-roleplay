-- latest_eligible is a 24-hour promotion flag, not a general Encounter eligibility requirement.
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
GRANT EXECUTE ON FUNCTION public.can_open_encounter_session(uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public.can_open_encounter_session(uuid) IS
  'Checks whether the JWT caller may open Encounter mode with a public, approved, rights-confirmed, non-deleted character; latest_eligible is only a promotion window, and NSFW characters require adult verification.';
