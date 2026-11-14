-- Disposable fixture for the bounded comment, character-story, Encounter-schedule and Story-session read RPCs.
DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
END
$roles$;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS private;

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;

CREATE TABLE public.characters (
  id uuid PRIMARY KEY,
  author_id uuid NOT NULL,
  visibility text NOT NULL,
  deleted_at timestamptz,
  is_nsfw boolean NOT NULL DEFAULT false,
  review_status text NOT NULL DEFAULT 'approved',
  rights_confirmed boolean NOT NULL DEFAULT true
);

CREATE TABLE public.character_stories (
  id uuid PRIMARY KEY,
  character_id uuid NOT NULL REFERENCES public.characters(id),
  opening_message text NOT NULL,
  visibility text NOT NULL,
  created_at timestamptz NOT NULL
);

CREATE TABLE public.character_schedules (
  id uuid PRIMARY KEY,
  character_id uuid NOT NULL REFERENCES public.characters(id),
  weekday smallint,
  day_type text NOT NULL,
  start_time time NOT NULL,
  end_time time NOT NULL,
  location_key text NOT NULL,
  activity text NOT NULL,
  priority smallint NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.chat_sessions (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL,
  character_id uuid NOT NULL,
  deleted_at timestamptz,
  chat_mode text NOT NULL DEFAULT 'story',
  session_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL
);

CREATE TABLE public.chat_messages (
  id uuid PRIMARY KEY,
  session_id uuid NOT NULL REFERENCES public.chat_sessions(id),
  role text NOT NULL,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL
);

CREATE TABLE public.character_comments (
  id uuid PRIMARY KEY,
  character_id uuid NOT NULL REFERENCES public.characters(id),
  author_id uuid NOT NULL,
  content text NOT NULL,
  parent_id uuid REFERENCES public.character_comments(id),
  is_whisper boolean NOT NULL DEFAULT false,
  is_deleted boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE OR REPLACE FUNCTION private.current_user_is_adult()
RETURNS boolean
LANGUAGE sql STABLE
AS $
  SELECT COALESCE(current_setting('request.jwt.claim.adult', true), 'false') = 'true';
$;

CREATE OR REPLACE FUNCTION private.comment_is_whisper_thread(p_comment_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT c.is_whisper OR COALESCE(parent.is_whisper, false)
    FROM public.character_comments c
    LEFT JOIN public.character_comments parent ON parent.id = c.parent_id
    WHERE c.id = p_comment_id
  ), false);
$$;

ALTER TABLE public.characters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.character_stories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY character_owner_read ON public.characters
  FOR SELECT TO authenticated USING (author_id = (SELECT auth.uid()));
CREATE POLICY story_owner_read ON public.character_stories
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.characters c WHERE c.id = character_id AND c.author_id = (SELECT auth.uid()))
  );
CREATE POLICY session_owner_read ON public.chat_sessions
  FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
CREATE POLICY message_owner_read ON public.chat_messages
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.chat_sessions s WHERE s.id = session_id AND s.user_id = (SELECT auth.uid()))
  );

GRANT SELECT ON public.characters, public.character_stories, public.chat_sessions, public.chat_messages TO authenticated;

