-- Public profile UI fields only. Row-level security still determines which profiles are visible.
-- Column grants prevent anonymous/authenticated Data API clients from selecting private profile fields.
revoke select on table public.profiles from anon, authenticated;

grant select (id, handle, nickname, avatar_url, bio)
on table public.profiles
to anon, authenticated;
