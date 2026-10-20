-- Anonymous visitors may read only the public profile fields.
-- They must never be able to attempt profile writes through the Data API.
revoke all privileges on table public.profiles from anon;

grant select (id, handle, nickname, avatar_url, bio)
on table public.profiles
to anon;
