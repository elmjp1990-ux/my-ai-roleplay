-- Limit public profile reads to fields used by the public profile/character UI.
-- RLS still controls which rows are visible; column grants limit which fields
-- anon/authenticated clients can select through the Data API.
revoke select on table public.profiles from anon, authenticated;

grant select (id, handle, nickname, avatar_url, bio)
on table public.profiles
to anon, authenticated;
