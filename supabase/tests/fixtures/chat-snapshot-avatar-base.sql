CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'CREATE ROLE anon NOLOGIN';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'CREATE ROLE authenticated NOLOGIN';
  END IF;
END;
$$;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS private;
CREATE SCHEMA IF NOT EXISTS storage;

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

CREATE TABLE public.account_deletion_requests (
  user_id uuid PRIMARY KEY
);

CREATE OR REPLACE FUNCTION public.account_is_active()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT auth.uid() IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.account_deletion_requests r WHERE r.user_id = auth.uid()
    );
$$;

CREATE OR REPLACE FUNCTION private.current_user_is_adult()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT true;
$$;

CREATE TABLE public.characters (
  id uuid PRIMARY KEY,
  author_id uuid NOT NULL,
  name text NOT NULL,
  gender text,
  age integer,
  avatar_url text,
  intro text,
  race text,
  style text,
  tags jsonb NOT NULL DEFAULT '[]'::jsonb,
  visibility text NOT NULL DEFAULT 'private',
  review_status text NOT NULL DEFAULT 'draft',
  is_nsfw boolean,
  first_published_at timestamptz,
  deletion_reason text,
  deleted_at timestamptz
);

CREATE TABLE public.character_illustrations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  character_id uuid NOT NULL REFERENCES public.characters(id),
  asset_type text NOT NULL,
  storage_path text NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.character_stories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  character_id uuid NOT NULL REFERENCES public.characters(id),
  opening_message text,
  visibility text NOT NULL DEFAULT 'private',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.chat_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL,
  name text NOT NULL,
  world_background text NOT NULL,
  scene_mode text NOT NULL,
  deleted_at timestamptz
);

CREATE TABLE public.chat_group_scenes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id),
  name text NOT NULL,
  description text NOT NULL DEFAULT '',
  position smallint NOT NULL
);

CREATE TABLE public.chat_group_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id),
  character_id uuid REFERENCES public.characters(id),
  position smallint NOT NULL,
  scene_id uuid REFERENCES public.chat_group_scenes(id),
  character_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE public.chat_group_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id),
  character_id uuid,
  speaker_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE public.chat_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  character_id uuid NOT NULL REFERENCES public.characters(id),
  character_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  deleted_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE storage.objects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id text NOT NULL,
  name text NOT NULL
);

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA auth, private, storage TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION private.current_user_is_adult() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.account_is_active() TO anon, authenticated;
GRANT SELECT ON public.characters, public.character_illustrations,
  public.chat_sessions, public.chat_groups, public.chat_group_members,
  public.account_deletion_requests, storage.objects TO anon, authenticated;
