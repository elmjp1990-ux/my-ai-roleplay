-- Minimal disposable fixture for the followed-author preview RPC.
CREATE TABLE public.characters (
  id uuid PRIMARY KEY,
  author_id uuid NOT NULL,
  name text NOT NULL,
  gender text,
  age integer,
  avatar_url text,
  avatar_video_path text,
  is_nsfw boolean NOT NULL DEFAULT false,
  visibility text NOT NULL,
  review_status text,
  intro text,
  race text,
  style text,
  tags text[],
  created_at timestamptz NOT NULL DEFAULT now(),
  first_published_at timestamptz,
  latest_eligible boolean NOT NULL DEFAULT true,
  deleted_at timestamptz
);

ALTER TABLE public.characters ENABLE ROW LEVEL SECURITY;
CREATE POLICY public_character_preview_read
  ON public.characters FOR SELECT TO authenticated
  USING (visibility = 'public' AND deleted_at IS NULL);
GRANT SELECT ON public.characters TO authenticated;

INSERT INTO public.characters (id, author_id, name, visibility, first_published_at)
SELECT
  ('10000000-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid,
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  'A-' || n,
  'public',
  '2026-01-01'::timestamptz + n * interval '1 day'
FROM generate_series(1, 6) AS n;

INSERT INTO public.characters (id, author_id, name, visibility, first_published_at)
SELECT
  ('11000000-0000-0000-0000-' || pg_catalog.lpad(n::text, 12, '0'))::uuid,
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
  'B-' || n,
  'public',
  '2026-01-01'::timestamptz + n * interval '1 day'
FROM generate_series(1, 6) AS n;

INSERT INTO public.characters (id, author_id, name, visibility, first_published_at, deleted_at)
VALUES
  ('20000000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A-private', 'private', now(), NULL),
  ('30000000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A-deleted', 'public', now(), now()),
  ('40000000-0000-0000-0000-000000000001', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 'C-private', 'private', now(), NULL);
