-- DRAFT ONLY — disposable PostgreSQL concurrency-test setup.
-- Applied only after the rollback verification in the CI-owned ephemeral database.
-- The database is discarded when the workflow job ends; never run on hosted Supabase.
\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS storage;
DO $storage_stub$
BEGIN
  -- Reuse Supabase Local's protected storage.objects; create only the stub
  -- required by plain disposable PostgreSQL when the relation is absent.
  IF pg_catalog.to_regclass('storage.objects') IS NULL THEN
    CREATE TABLE storage.objects (bucket_id text NOT NULL, name text NOT NULL);
  END IF;
END;
$storage_stub$;

\i supabase/drafts/chat-deletion-cumulative-turn-statistics-proposal.sql
\i supabase/drafts/chat-deletion-direct-parent-delete-privilege-guard.sql
\i supabase/drafts/seed-character-deletion-legacy-fixtures.sql
\i supabase/drafts/character-history-aware-deletion.sql
\i supabase/drafts/account-deletion-character-preservation-draft.sql
\i supabase/drafts/account-is-active-auth-user-existence-guard.sql
\i supabase/drafts/account-archived-character-session-insert-guard.sql
\i supabase/drafts/account-deletion-character-child-write-freeze.sql
\i supabase/drafts/character-deletion-existing-chat-continuation.sql
\i supabase/drafts/prepare-account-deletion-character-preservation-integration.sql
\i supabase/drafts/account-deletion-worker-atomic-lease.sql

INSERT INTO auth.users (id) VALUES
  ('10000000-0000-4000-8000-000000000030'),
  ('10000000-0000-4000-8000-000000000031'),
  ('10000000-0000-4000-8000-000000000032'),
  ('10000000-0000-4000-8000-000000000033'),
  ('10000000-0000-4000-8000-000000000034'),
  ('10000000-0000-4000-8000-000000000035'),
  ('10000000-0000-4000-8000-000000000036')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, handle, nickname) VALUES
  ('10000000-0000-4000-8000-000000000030', 'pr200-race-author', 'Race Test Author'),
  ('10000000-0000-4000-8000-000000000031', 'pr200-race-player', 'Race Test Player'),
  ('10000000-0000-4000-8000-000000000032', 'pr200-asset-author', 'Asset Test Author'),
  ('10000000-0000-4000-8000-000000000033', 'pr200-lease-author', 'Lease Test Author'),
  ('10000000-0000-4000-8000-000000000034', 'pr200-lease-author-2', 'Lease Test Author 2'),
  ('10000000-0000-4000-8000-000000000035', 'pr200-lease-race-claim', 'Lease Claim Race'),
  ('10000000-0000-4000-8000-000000000036', 'pr200-lease-race-cancel', 'Lease Cancel Race')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.characters (id, author_id, name, visibility, review_status, rights_confirmed)
VALUES
  ('20000000-0000-4000-8000-000000000030', '10000000-0000-4000-8000-000000000030', 'Delete race character', 'public', 'approved', true),
  ('20000000-0000-4000-8000-000000000031', '10000000-0000-4000-8000-000000000030', 'Archive race character', 'public', 'approved', true),
  ('20000000-0000-4000-8000-000000000032', '10000000-0000-4000-8000-000000000032', 'Asset race draft A', 'private', 'draft', true),
  ('20000000-0000-4000-8000-000000000033', '10000000-0000-4000-8000-000000000032', 'Asset race target A', 'public', 'approved', true),
  ('20000000-0000-4000-8000-000000000034', '10000000-0000-4000-8000-000000000032', 'Asset race draft B', 'private', 'draft', true),
  ('20000000-0000-4000-8000-000000000035', '10000000-0000-4000-8000-000000000032', 'Asset race target B', 'public', 'approved', true);

INSERT INTO public.character_schedules (
  id, character_id, weekday, day_type, start_time, end_time, location_key, activity
) VALUES (
  '40000000-0000-4000-8000-000000000031',
  '20000000-0000-4000-8000-000000000031',
  1, 'any', '09:00', '10:00', 'cafe', 'Initial schedule activity'
);

INSERT INTO public.character_private_info (character_id, author_id, private_info)
VALUES (
  '20000000-0000-4000-8000-000000000031',
  '10000000-0000-4000-8000-000000000030',
  'Concurrency fixture private info'
);

UPDATE public.characters
SET avatar_video_path =
  '10000000-0000-4000-8000-000000000032/20000000-0000-4000-8000-000000000034/avatar.mp4'
WHERE id = '20000000-0000-4000-8000-000000000034';

INSERT INTO public.character_illustrations (
  id, character_id, author_id, storage_path, asset_type, sort_order
) VALUES (
  '30000000-0000-4000-8000-000000000032',
  '20000000-0000-4000-8000-000000000032',
  '10000000-0000-4000-8000-000000000032',
  '10000000-0000-4000-8000-000000000032/20000000-0000-4000-8000-000000000032/30000000-0000-4000-8000-000000000032.jpg',
  'primary', 0
), (
  '30000000-0000-4000-8000-000000000034',
  '20000000-0000-4000-8000-000000000034',
  '10000000-0000-4000-8000-000000000032',
  '10000000-0000-4000-8000-000000000032/20000000-0000-4000-8000-000000000034/30000000-0000-4000-8000-000000000034.jpg',
  'primary', 0
);
