-- Allow authenticated users to read their own membership status.
-- RLS on public.profiles still restricts authenticated SELECT to auth.uid() = id.
GRANT SELECT (membership_tier, membership_expires_at)
ON TABLE public.profiles
TO authenticated;
