-- Membership data must not be granted as a broadly readable profiles column.
-- The owner-scoped get_my_private_profile_data() RPC is used instead.
REVOKE SELECT (membership_tier, membership_expires_at)
ON TABLE public.profiles
FROM anon, authenticated;
