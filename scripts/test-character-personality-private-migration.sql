\set ON_ERROR_STOP on

DO $$
BEGIN
  CREATE ROLE anon;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
  CREATE ROLE authenticated;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
  CREATE ROLE service_role;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- This script runs only against the disposable PostgreSQL service in GitHub Actions.
CREATE TABLE public.characters (
  id uuid PRIMARY KEY,
  author_id uuid NOT NULL,
  personality_profile jsonb NOT NULL DEFAULT '{}'::jsonb,
  name text,
  title text,
  gender text,
  age integer,
  avatar_url text,
  visibility text,
  review_status text,
  created_at timestamptz,
  intro text,
  race text,
  style text,
  tags jsonb,
  first_published_at timestamptz,
  latest_eligible boolean,
  rights_confirmed boolean,
  deleted_at timestamptz,
  deletion_reason text,
  phone_settings jsonb,
  nsfw_workplace_warning boolean,
  is_nsfw boolean,
  avatar_video_path text
);
GRANT SELECT ON public.characters TO anon, authenticated, service_role;

-- Deliberately omit personality_profile: the migration must add it.
CREATE TABLE public.character_private_info (
  character_id uuid PRIMARY KEY,
  author_id uuid NOT NULL,
  private_info text NOT NULL DEFAULT ''
);

INSERT INTO public.characters (id, author_id, personality_profile) VALUES
  ('00000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', '{"coreTraits":"initial private profile A"}'),
  ('00000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001', '{"coreTraits":"initial private profile B"}'),
  ('00000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001', '{}');

\i supabase/migrations/20261104062017_move_character_personality_profile_to_private_info.sql
\i supabase/migrations/20261104095000_restrict_legacy_personality_profile_select.sql

DO $$
BEGIN
  IF has_table_privilege('anon', 'public.characters', 'SELECT') THEN
    RAISE EXCEPTION 'anon must not retain table-level SELECT on public.characters';
  END IF;
  IF has_table_privilege('authenticated', 'public.characters', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated must not retain table-level SELECT on public.characters';
  END IF;
  IF has_column_privilege('anon', 'public.characters', 'personality_profile', 'SELECT')
     OR has_column_privilege('authenticated', 'public.characters', 'personality_profile', 'SELECT') THEN
    RAISE EXCEPTION 'legacy personality_profile must not be selectable by anon/authenticated';
  END IF;
  IF NOT has_column_privilege('anon', 'public.characters', 'name', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.characters', 'name', 'SELECT') THEN
    RAISE EXCEPTION 'approved public columns must remain selectable';
  END IF;
  IF NOT has_table_privilege('service_role', 'public.characters', 'SELECT') THEN
    RAISE EXCEPTION 'service_role must retain table-level SELECT';
  END IF;
END;
$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.character_private_info
    WHERE character_id = '00000000-0000-4000-8000-000000000001'
      AND personality_profile->>'coreTraits' = 'initial private profile A'
      AND private_info = ''
  ) THEN
    RAISE EXCEPTION 'new private row did not receive personality profile A';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.character_private_info
    WHERE character_id = '00000000-0000-4000-8000-000000000002'
      AND personality_profile->>'coreTraits' = 'initial private profile B'
  ) THEN
    RAISE EXCEPTION 'new private row did not receive personality profile B';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.character_private_info
    WHERE character_id = '00000000-0000-4000-8000-000000000003'
  ) THEN
    RAISE EXCEPTION 'empty personality profile should not create a private row';
  END IF;
END;
$$;

-- Existing private content must remain intact. A non-empty private profile wins;
-- an empty profile may be filled from the legacy column.
UPDATE public.character_private_info
SET private_info = 'preserve hidden story A',
    personality_profile = '{"coreTraits":"author-edited profile A"}'
WHERE character_id = '00000000-0000-4000-8000-000000000001';

INSERT INTO public.character_private_info (character_id, author_id, private_info, personality_profile)
VALUES (
  '00000000-0000-4000-8000-000000000003',
  '10000000-0000-4000-8000-000000000001',
  'preserve hidden story C',
  '{}'
);

UPDATE public.characters
SET personality_profile = '{"coreTraits":"legacy changed A"}'
WHERE id = '00000000-0000-4000-8000-000000000001';

UPDATE public.characters
SET personality_profile = '{"coreTraits":"copy into empty private profile C"}'
WHERE id = '00000000-0000-4000-8000-000000000003';

\i supabase/migrations/20261104062017_move_character_personality_profile_to_private_info.sql

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.character_private_info
    WHERE character_id = '00000000-0000-4000-8000-000000000001'
      AND private_info = 'preserve hidden story A'
      AND personality_profile->>'coreTraits' = 'author-edited profile A'
  ) THEN
    RAISE EXCEPTION 'migration overwrote existing private content or author-edited profile';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.character_private_info
    WHERE character_id = '00000000-0000-4000-8000-000000000003'
      AND private_info = 'preserve hidden story C'
      AND personality_profile->>'coreTraits' = 'copy into empty private profile C'
  ) THEN
    RAISE EXCEPTION 'migration failed to fill an empty private profile while preserving hidden story';
  END IF;
END;
$$;
