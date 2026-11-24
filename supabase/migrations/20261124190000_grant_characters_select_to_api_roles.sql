-- Restore Data API read access for characters.
-- Row visibility remains governed by the existing RLS policies.
GRANT SELECT ON TABLE public.characters TO anon, authenticated;
