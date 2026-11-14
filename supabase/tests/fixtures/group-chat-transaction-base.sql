-- Minimal isolated schema contract for the group-chat transaction migration.
-- This is intentionally disposable and is never connected to Hosted Supabase.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END
$$;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  aud text,
  role text,
  email text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
-- The Supabase Postgres image already provides auth.users and auth.uid().
-- Keep its Auth schema intact; tests use explicit user IDs through service RPCs.

CREATE TABLE public.account_deletion_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL
);

CREATE TABLE public.chat_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES auth.users(id),
  name text NOT NULL DEFAULT 'Test group',
  archived_at timestamptz,
  deleted_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.chat_group_scenes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  name text NOT NULL DEFAULT 'Test scene'
);

CREATE TABLE public.chat_group_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  character_id uuid NOT NULL,
  position integer NOT NULL,
  scene_id uuid,
  character_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE public.chat_group_turns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  request_key uuid NOT NULL,
  request_content text NOT NULL,
  status text NOT NULL DEFAULT 'completed',
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chat_group_turns_status_check CHECK (status = 'completed'),
  UNIQUE (group_id, request_key)
);

CREATE TABLE public.chat_group_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  scene_id uuid,
  turn_id uuid NOT NULL REFERENCES public.chat_group_turns(id) ON DELETE CASCADE,
  sequence_no integer NOT NULL,
  speaker_type text NOT NULL,
  character_id uuid,
  content text NOT NULL,
  speaker_snapshot jsonb,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (group_id, turn_id, sequence_no)
);

CREATE TABLE public.chat_group_turn_charges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  group_turn_id uuid NOT NULL UNIQUE REFERENCES public.chat_group_turns(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  request_key uuid NOT NULL,
  member_count integer NOT NULL,
  cost integer NOT NULL,
  silver_charged integer NOT NULL DEFAULT 0,
  diamonds_charged integer NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'settled',
  CONSTRAINT chat_group_turn_charges_status_check CHECK (status = 'settled'),
  CONSTRAINT chat_group_turn_charges_group_request_key UNIQUE (group_id, request_key)
);

CREATE TABLE public.wallet_accounts (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  silver_coins integer NOT NULL DEFAULT 0 CHECK (silver_coins >= 0),
  diamonds integer NOT NULL DEFAULT 0 CHECK (diamonds >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.wallet_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  currency_type text NOT NULL,
  amount integer NOT NULL,
  biz_type text NOT NULL,
  reference_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.append_chat_group_mock_turn(uuid, uuid, text)
RETURNS uuid LANGUAGE sql AS $$ SELECT NULL::uuid $$;

GRANT USAGE ON SCHEMA public, auth TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public, auth TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public, auth TO service_role;
