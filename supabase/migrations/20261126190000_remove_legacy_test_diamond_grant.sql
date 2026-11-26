-- Retire the obsolete one-time 200-diamond test grant.
-- Historical migrations remain immutable; this forward migration removes the
-- live RPC so the new package-based test flow can be introduced cleanly.
drop function if exists public.test_grant_diamonds_200();
