-- DRAFT ONLY: do not apply to the hosted project until local migration replay
-- and RLS regression tests pass.
--
-- Fixes stale-JWT access after Auth Admin deletion. Supabase access tokens are
-- stateless and remain valid until exp; deleting auth.users removes refresh
-- sessions but does not invalidate an already-issued JWT. The account guard
-- must therefore verify that auth.uid() still has a row in auth.users.
--
-- Preserve the current SECURITY DEFINER / empty search_path / role grants.
CREATE OR REPLACE FUNCTION public.account_is_active()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT auth.uid() IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM auth.users AS u
       WHERE u.id = auth.uid()
     )
     AND NOT EXISTS (
       SELECT 1
       FROM public.account_deletion_requests AS r
       WHERE r.user_id = auth.uid()
     );
$function$;

-- Explicitly keep the function unavailable to PUBLIC / anon. Preserve the
-- currently observed authenticated and service_role execution grants.
REVOKE ALL ON FUNCTION public.account_is_active() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.account_is_active() TO authenticated, service_role;
