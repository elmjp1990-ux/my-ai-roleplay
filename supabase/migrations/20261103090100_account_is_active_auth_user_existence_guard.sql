-- PR #200: reject still-valid access JWTs after Auth Admin deletion.
-- Fresh incremental migration; do not rewrite or replay historical migrations.
-- Apply only after disposable replay and stale-token/RLS regression tests pass.
--
-- Access JWTs are stateless and may remain cryptographically valid until exp.
-- Auth Admin deletion removes auth.users and cascades account_deletion_requests,
-- so checking only auth.uid() and the request table is insufficient.
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

REVOKE ALL ON FUNCTION public.account_is_active() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.account_is_active() TO authenticated, service_role;
