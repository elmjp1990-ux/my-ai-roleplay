\set ON_ERROR_STOP on
BEGIN;

CREATE SCHEMA IF NOT EXISTS auth;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN; END IF;
END $$;
CREATE TABLE auth.users (id uuid PRIMARY KEY);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE TABLE public.characters (id uuid PRIMARY KEY);
CREATE TABLE public.chat_sessions (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL,
  character_id uuid,
  chat_mode text NOT NULL,
  deleted_at timestamptz
);
CREATE TABLE public.chat_messages (
  id uuid PRIMARY KEY,
  session_id uuid NOT NULL REFERENCES public.chat_sessions(id),
  role text NOT NULL,
  content text NOT NULL
);
CREATE TABLE public.chat_turn_charges (
  turn_id uuid PRIMARY KEY,
  session_id uuid NOT NULL REFERENCES public.chat_sessions(id),
  user_id uuid NOT NULL,
  user_message_id uuid NOT NULL REFERENCES public.chat_messages(id),
  expected_assistant_message_id uuid NOT NULL REFERENCES public.chat_messages(id),
  assistant_message_id uuid REFERENCES public.chat_messages(id),
  status text NOT NULL
);
CREATE TABLE public.story_relationship_states (
  session_id uuid PRIMARY KEY REFERENCES public.chat_sessions(id),
  user_id uuid NOT NULL,
  character_id uuid,
  affinity integer NOT NULL DEFAULT 0,
  relationship_stage text NOT NULL DEFAULT 'first_meeting',
  turn_count_since_summary integer NOT NULL DEFAULT 0,
  last_processed_batch integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.story_relationship_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.chat_sessions(id),
  user_id uuid NOT NULL,
  character_id uuid,
  batch_number integer NOT NULL,
  first_turn_number integer NOT NULL,
  last_turn_number integer NOT NULL,
  source_turn_ids uuid[] NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  summary text,
  affinity_delta integer,
  evaluation jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  UNIQUE (session_id, batch_number),
  CHECK (
    (status = 'completed' AND summary IS NOT NULL AND affinity_delta IS NOT NULL AND processed_at IS NOT NULL)
    OR status <> 'completed'
  )
);

\ir ../supabase/migrations/20261106090000_story_turn_affinity_and_phone_events.sql
\ir ../supabase/migrations/20261106110000_harden_story_turn_service_role_claims.sql
\ir ../supabase/migrations/20261106120000_fix_story_turn_evaluation_reserved_charge.sql
\ir ../supabase/migrations/20261106140000_expand_story_phone_events_to_five_fields.sql
\ir ../supabase/migrations/20261105223613_ai_model_usage_and_memory_summaries.sql
\ir ../supabase/migrations/20261110120000_story_phone_state_and_memory_summary_read.sql

INSERT INTO auth.users(id) VALUES
  ('10000000-0000-4000-8000-000000000001'),
  ('10000000-0000-4000-8000-000000000002');
INSERT INTO public.characters(id) VALUES ('20000000-0000-4000-8000-000000000001');
INSERT INTO public.chat_sessions(id,user_id,character_id,chat_mode) VALUES
  ('30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','story'),
  ('30000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','story');
INSERT INTO public.story_relationship_states(session_id,user_id,character_id,affinity)
VALUES
  ('30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',10),
  ('30000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001',0);

INSERT INTO public.chat_messages(id,session_id,role,content) VALUES
  ('40000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','user','Hi'),
  ('50000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','assistant','Hello'),
  ('40000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000001','user','Turn two'),
  ('50000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000001','assistant','Reply two'),
  ('40000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000001','user','Turn three'),
  ('50000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000001','assistant','Reply three'),
  ('40000000-0000-4000-8000-000000000004','30000000-0000-4000-8000-000000000001','user','Turn four'),
  ('50000000-0000-4000-8000-000000000004','30000000-0000-4000-8000-000000000001','assistant','Reply four'),
  ('40000000-0000-4000-8000-000000000005','30000000-0000-4000-8000-000000000001','user','Turn five'),
  ('50000000-0000-4000-8000-000000000005','30000000-0000-4000-8000-000000000001','assistant','Reply five');

INSERT INTO public.chat_turn_charges(turn_id,session_id,user_id,user_message_id,expected_assistant_message_id,assistant_message_id,status) VALUES
  ('60000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001',NULL,'reserved'),
  ('60000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000002','settled'),
  ('60000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000003','50000000-0000-4000-8000-000000000003','50000000-0000-4000-8000-000000000003','settled'),
  ('60000000-0000-4000-8000-000000000004','30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000004','50000000-0000-4000-8000-000000000004','50000000-0000-4000-8000-000000000004','settled'),
  ('60000000-0000-4000-8000-000000000005','30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000005','50000000-0000-4000-8000-000000000005','50000000-0000-4000-8000-000000000005','settled');

SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SELECT set_config('request.jwt.claim.role','service_role',true);
DO $ BEGIN
  IF NOT public.is_service_role_request() THEN
    RAISE EXCEPTION 'service-role test setup failed: role=%, claims=%',
      current_setting('request.jwt.claim.role', true),
      current_setting('request.jwt.claims', true);
  END IF;
END $;
SELECT public.queue_story_turn_evaluation(
  '60000000-0000-4000-8000-000000000001',
  '30000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000001',
  '40000000-0000-4000-8000-000000000001',
  '50000000-0000-4000-8000-000000000001',
  2,
  'A meaningful trust-building moment',
  '[{"event_type":"notification","title":"💭江辰遠目前的想法","body":"他正在思考今天的安排。"},{"event_type":"notification","title":"📱最近收到的訊息","body":"目前沒有新的訊息。"},{"event_type":"notification","title":"📍江辰遠衣著／姿勢","body":"穿著目前已知的休閒襯衫。"},{"event_type":"notification","title":"📍玩家衣著／姿勢","body":"目前沒有足夠資訊。"},{"event_type":"notification","title":"🗒️江辰遠待辦事項","body":"目前沒有待辦事項。"},{"event_type":"notification","title":"欄位六","body":"內容六。"},{"event_type":"notification","title":"欄位七","body":"內容七。"},{"event_type":"notification","title":"欄位八","body":"內容八。"}]'::jsonb
);
DO $$
DECLARE result jsonb;
BEGIN
  result := public.apply_story_turn_evaluation('60000000-0000-4000-8000-000000000001');
  IF result->>'status' <> 'waiting_for_settlement' THEN
    RAISE EXCEPTION 'pending wallet charge must not apply side effects';
  END IF;
END $$;

DO $$
BEGIN
  PERFORM set_config('request.jwt.claim.role','',true);
  PERFORM set_config('request.jwt.claims','{"role":"authenticated"}',true);
  BEGIN
    PERFORM public.apply_story_turn_evaluation('60000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'authenticated role unexpectedly passed service-role guard';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'service_role_required' THEN RAISE; END IF;
  END;
END $$;
SELECT set_config('request.jwt.claim.role','service_role',true);
UPDATE public.chat_turn_charges SET status='settled', assistant_message_id=expected_assistant_message_id
WHERE turn_id='60000000-0000-4000-8000-000000000001';
SELECT set_config('request.jwt.claim.role','',true);
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);

DO $$
DECLARE result jsonb; current_affinity integer; event_count integer;
BEGIN
  result := public.apply_story_turn_evaluation('60000000-0000-4000-8000-000000000001');
  IF result->>'status' <> 'applied' OR (result->>'affinity')::integer <> 12 THEN
    RAISE EXCEPTION 'first affinity application failed: %', result;
  END IF;
  result := public.apply_story_turn_evaluation('60000000-0000-4000-8000-000000000001');
  IF result->>'idempotent' <> 'true' THEN RAISE EXCEPTION 'duplicate application was not idempotent'; END IF;
  SELECT affinity INTO current_affinity FROM public.story_relationship_states
  WHERE session_id='30000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO event_count FROM public.story_phone_states
  WHERE source_turn_id='60000000-0000-4000-8000-000000000001';
  IF current_affinity <> 12 OR event_count <> 8 THEN
    RAISE EXCEPTION 'phone state snapshots duplicated or missing';
  END IF;
  SELECT count(*) INTO event_count FROM public.story_phone_events
  WHERE turn_id='60000000-0000-4000-8000-000000000001';
  IF event_count <> 0 THEN
    RAISE EXCEPTION 'replaceable notification snapshots leaked into event history';
  END IF;
END $$;

SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
DO $
DECLARE event_count integer;
BEGIN
  SELECT count(*) INTO event_count FROM public.get_story_phone_state('30000000-0000-4000-8000-000000000001');
  IF event_count <> 8 THEN RAISE EXCEPTION 'owner cannot read all eight current phone fields'; END IF;
  SELECT count(*) INTO event_count FROM public.get_story_phone_events('30000000-0000-4000-8000-000000000001');
  IF event_count <> 0 THEN RAISE EXCEPTION 'status snapshots must not render as historical events'; END IF;
END $;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
DO $
DECLARE state_count integer; event_count integer;
BEGIN
  SELECT count(*) INTO state_count FROM public.get_story_phone_state('30000000-0000-4000-8000-000000000001');
  SELECT count(*) INTO event_count FROM public.get_story_phone_events('30000000-0000-4000-8000-000000000001');
  IF state_count <> 0 OR event_count <> 0 THEN RAISE EXCEPTION 'cross-owner phone data read was allowed'; END IF;
END $;

INSERT INTO public.ai_model_usage (
  user_id,session_id,generation_type,batch_number,source_turn_ids,model,status,summary,processed_at
) VALUES (
  '10000000-0000-4000-8000-000000000001',
  '30000000-0000-4000-8000-000000000001',
  'memory_summary',1,
  ARRAY[
    '60000000-0000-4000-8000-000000000001',
    '60000000-0000-4000-8000-000000000002',
    '60000000-0000-4000-8000-000000000003',
    '60000000-0000-4000-8000-000000000004',
    '60000000-0000-4000-8000-000000000005'
  ]::uuid[],
  'openai/gpt-oss-20b','completed','這是已完成的 AI 累積回憶摘要。',now()
);
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
DO $
DECLARE row_value record;
BEGIN
  SELECT * INTO row_value FROM public.get_story_memory_summary('30000000-0000-4000-8000-000000000001');
  IF row_value.summary <> '這是已完成的 AI 累積回憶摘要。' OR row_value.generation_status <> 'completed' THEN
    RAISE EXCEPTION 'owner cannot read the latest AI memory summary';
  END IF;
END $;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
DO $
DECLARE row_count integer;
BEGIN
  SELECT count(*) INTO row_count FROM public.get_story_memory_summary('30000000-0000-4000-8000-000000000001');
  IF row_count <> 0 THEN RAISE EXCEPTION 'cross-owner memory summary read was allowed'; END IF;
END $;

SELECT set_config('request.jwt.claim.role','service_role',true);
SELECT public.complete_story_relationship_batch(
  '30000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000001',
  1,
  ARRAY[
    '60000000-0000-4000-8000-000000000001',
    '60000000-0000-4000-8000-000000000002',
    '60000000-0000-4000-8000-000000000003',
    '60000000-0000-4000-8000-000000000004',
    '60000000-0000-4000-8000-000000000005'
  ]::uuid[],
  '五回合累積記憶摘要。',
  -2,
  '{"reason":"The initial micro-adjustment was slightly optimistic."}'::jsonb
);
DO $$
DECLARE result jsonb; current_affinity integer; current_batch integer; current_count integer;
BEGIN
  result := public.complete_story_relationship_batch(
    '30000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    1,
    ARRAY[
      '60000000-0000-4000-8000-000000000001',
      '60000000-0000-4000-8000-000000000002',
      '60000000-0000-4000-8000-000000000003',
      '60000000-0000-4000-8000-000000000004',
      '60000000-0000-4000-8000-000000000005'
    ]::uuid[],
    '五回合累積記憶摘要。',
    -2,
    '{"reason":"The initial micro-adjustment was slightly optimistic."}'::jsonb
  );
  IF result->>'idempotent' <> 'true' THEN RAISE EXCEPTION 'batch retry was not idempotent'; END IF;
  SELECT affinity,last_processed_batch,turn_count_since_summary
    INTO current_affinity,current_batch,current_count
  FROM public.story_relationship_states
  WHERE session_id='30000000-0000-4000-8000-000000000001';
  IF current_affinity <> 10 OR current_batch <> 1 OR current_count <> 0 THEN
    RAISE EXCEPTION 'batch calibration failed or applied more than once';
  END IF;
END $$;

ROLLBACK;
