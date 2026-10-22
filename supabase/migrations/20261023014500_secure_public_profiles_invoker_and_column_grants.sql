-- Remove broad table grants: RLS alone does not constrain TRUNCATE/REFERENCES/TRIGGER
-- and table-level SELECT would allow authenticated users to read private profile columns.
REVOKE ALL PRIVILEGES ON TABLE public.profiles FROM anon, authenticated;
REVOKE ALL PRIVILEGES (id, handle, nickname, avatar_url, bio, status, created_at, persona_presets, birthdate, follower_count)
  ON TABLE public.profiles FROM anon, authenticated;

GRANT SELECT (id, handle, nickname, avatar_url, bio, follower_count)
  ON TABLE public.profiles TO anon, authenticated;
GRANT INSERT (id, handle, nickname, avatar_url, bio, persona_presets, birthdate)
  ON TABLE public.profiles TO authenticated;
GRANT UPDATE (id, handle, nickname, avatar_url, bio, persona_presets, birthdate)
  ON TABLE public.profiles TO authenticated;

DROP POLICY IF EXISTS profiles_public_read_six_columns ON public.profiles;
CREATE POLICY profiles_public_read_six_columns
  ON public.profiles FOR SELECT TO anon, authenticated
  USING (true);

ALTER VIEW public.public_profiles SET (security_invoker = true);
