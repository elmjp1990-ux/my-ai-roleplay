-- The one-time diamond grant is a test helper, not a client-facing purchase API.
-- Prevent signed-in users from granting themselves test currency through PostgREST.
-- Keep execution available only to service_role for controlled test administration.
REVOKE EXECUTE ON FUNCTION public.test_grant_diamonds_200() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.test_grant_diamonds_200() TO service_role;
