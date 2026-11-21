-- Disposable synthetic-schema integration test for per-turn Encounter affinity.
-- This file is CI-only. It applies the formal migration inside a transaction and
-- rolls back every DDL and fixture row. Never run against Hosted Supabase.
\set ON_ERROR_STOP on
BEGIN;

-- The synthetic current-state fixture intentionally omits application routines.
-- Supply the exact helper contracts required by the formal migration.
CREATE OR REPLACE FUNCTION public.is_service_role_request()
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim.role', true), '') = 'service_role',
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role') = 'service_role',
    false
  );
$$;

CREATE OR REPLACE FUNCTION public.story_relationship_stage_for_affinity(p_affinity integer)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p_affinity <= -80 THEN 'hostile'
    WHEN p_affinity <= -40 THEN 'dislike'
    WHEN p_affinity < 0 THEN 'wary'
    WHEN p_affinity < 20 THEN 'first_meeting'
    WHEN p_affinity < 45 THEN 'acquaintance'
    WHEN p_affinity < 70 THEN 'close'
    WHEN p_affinity < 90 THEN 'intimate'
    ELSE 'special'
  END;
$$;

\echo 'Applying formal Encounter per-turn affinity migration'
\i supabase/migrations/20261120020000_encounter_per_turn_affinity.sql

INSERT INTO auth.users (id)
VALUES ('a1000000-0000-4000-8000-000000000001');
INSERT INTO public.profiles (id, handle, nickname)
VALUES ('a1000000-0000-4000-8000-000000000001', 'affinity-ci-user', 'Affinity CI');
INSERT INTO public.characters (id, author_id, name, visibility, review_status, rights_confirmed, first_published_at)
VALUES ('a2000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'Affinity CI Character', 'public', 'approved', true, now());
INSERT INTO public.encounter_character_state
  (user_id, character_id, affinity, relationship_stage, first_met_at, last_interaction_at)
VALUES
  ('a1000000-0000-4000-8000-000000000001',
   'a2000000-0000-4000-8000-000000000001', 25, 'acquaintance', now(), now());

SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT public.create_encounter_session_with_lifecycle(
  'a3000000-0000-4000-8000-000000000001',
  'a1000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001',
  'Affinity CI Character', '{}'::jsonb, '{}'::jsonb, 'ci-location',
  now(), now() + interval '1 hour'
);

DO $test$
DECLARE
  v_session public.chat_sessions%ROWTYPE;
  v_result jsonb;
  v_affinity integer;
  v_story_affinity integer;
BEGIN
  SELECT * INTO v_session FROM public.chat_sessions
  WHERE id='a3000000-0000-4000-8000-000000000001';
  IF v_session.session_data #>> '{encounter,affinity}' <> '25'
     OR v_session.session_data #>> '{encounter,relationshipStage}' <> 'acquaintance' THEN
    RAISE EXCEPTION 'new Encounter session did not inherit canonical affinity';
  END IF;

  INSERT INTO public.chat_messages (id,session_id,role,content)
  VALUES ('a4000000-0000-4000-8000-000000000001',
          'a3000000-0000-4000-8000-000000000001','user','hello');
  INSERT INTO public.chat_turn_charges
    (turn_id,user_id,session_id,user_message_id,expected_assistant_message_id,status,settled_at)
  VALUES
    ('a5000000-0000-4000-8000-000000000001',
     'a1000000-0000-4000-8000-000000000001',
     'a3000000-0000-4000-8000-000000000001',
     'a4000000-0000-4000-8000-000000000001',
     'a6000000-0000-4000-8000-000000000001','settled',now());

  v_result := public.apply_encounter_turn_affinity(
    'a5000000-0000-4000-8000-000000000001',
    'a1000000-0000-4000-8000-000000000001',
    'a2000000-0000-4000-8000-000000000001',3
  );
  IF (v_result->>'affinity')::integer <> 28 OR (v_result->>'idempotent')::boolean THEN
    RAISE EXCEPTION 'first per-turn affinity application returned an unexpected result: %', v_result;
  END IF;

  v_result := public.apply_encounter_turn_affinity(
    'a5000000-0000-4000-8000-000000000001',
    'a1000000-0000-4000-8000-000000000001',
    'a2000000-0000-4000-8000-000000000001',3
  );
  IF (v_result->>'affinity')::integer <> 28 OR NOT (v_result->>'idempotent')::boolean THEN
    RAISE EXCEPTION 'duplicate turn replay was not idempotent: %', v_result;
  END IF;

  INSERT INTO public.chat_sessions
    (id,user_id,character_id,character_name,character_snapshot,session_data,chat_mode)
  VALUES
    ('a7000000-0000-4000-8000-000000000001',
     'a1000000-0000-4000-8000-000000000001',
     'a2000000-0000-4000-8000-000000000001',
     'Affinity CI Character','{}'::jsonb,'{}'::jsonb,'story');
  INSERT INTO public.story_relationship_states
    (session_id,user_id,character_id,origin_mode,affinity,relationship_stage,
     origin_affinity,origin_relationship_stage,imported_memories)
  VALUES
    ('a7000000-0000-4000-8000-000000000001',
     'a1000000-0000-4000-8000-000000000001',
     'a2000000-0000-4000-8000-000000000001',
     'fresh_story',40,'acquaintance',40,'acquaintance','[]'::jsonb);
  UPDATE public.chat_sessions SET session_data='{"affinityMode":"shared"}'::jsonb
  WHERE id='a7000000-0000-4000-8000-000000000001';
  SELECT affinity INTO v_affinity FROM public.encounter_character_state
  WHERE user_id='a1000000-0000-4000-8000-000000000001'
    AND character_id='a2000000-0000-4000-8000-000000000001';
  IF v_affinity<>40 THEN RAISE EXCEPTION 'shared Story mode did not seed Encounter affinity: %',v_affinity; END IF;

  UPDATE public.encounter_character_state SET affinity=44,relationship_stage='acquaintance'
  WHERE user_id='a1000000-0000-4000-8000-000000000001'
    AND character_id='a2000000-0000-4000-8000-000000000001';
  SELECT affinity INTO v_story_affinity FROM public.story_relationship_states
  WHERE session_id='a7000000-0000-4000-8000-000000000001';
  IF v_story_affinity<>44 THEN RAISE EXCEPTION 'Encounter affinity did not sync to shared Story: %',v_story_affinity; END IF;

  UPDATE public.story_relationship_states SET affinity=48,relationship_stage='close'
  WHERE session_id='a7000000-0000-4000-8000-000000000001';
  SELECT affinity INTO v_affinity FROM public.encounter_character_state
  WHERE user_id='a1000000-0000-4000-8000-000000000001'
    AND character_id='a2000000-0000-4000-8000-000000000001';
  IF v_affinity<>48 THEN RAISE EXCEPTION 'shared Story affinity did not sync back to Encounter: %',v_affinity; END IF;

  INSERT INTO public.chat_sessions
    (id,user_id,character_id,character_name,character_snapshot,session_data,chat_mode)
  VALUES
    ('a8000000-0000-4000-8000-000000000001',
     'a1000000-0000-4000-8000-000000000001',
     'a2000000-0000-4000-8000-000000000001',
     'Affinity CI Character','{}'::jsonb,'{"affinityMode":"independent"}'::jsonb,'story');
  INSERT INTO public.story_relationship_states
    (session_id,user_id,character_id,origin_mode,affinity,relationship_stage,
     origin_affinity,origin_relationship_stage,imported_memories)
  VALUES
    ('a8000000-0000-4000-8000-000000000001',
     'a1000000-0000-4000-8000-000000000001',
     'a2000000-0000-4000-8000-000000000001',
     'fresh_story',70,'intimate',70,'intimate','[]'::jsonb);
  UPDATE public.story_relationship_states SET affinity=75,relationship_stage='intimate'
  WHERE session_id='a8000000-0000-4000-8000-000000000001';
  SELECT affinity INTO v_affinity FROM public.encounter_character_state
  WHERE user_id='a1000000-0000-4000-8000-000000000001'
    AND character_id='a2000000-0000-4000-8000-000000000001';
  IF v_affinity<>48 THEN RAISE EXCEPTION 'independent Story affinity leaked into Encounter: %',v_affinity; END IF;
END
$test$;

SELECT public.create_encounter_session_with_lifecycle(
  'a9000000-0000-4000-8000-000000000001',
  'a1000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001',
  'Affinity CI Character', '{}'::jsonb, '{}'::jsonb, 'ci-location-2',
  now(), now() + interval '1 hour'
);

DO $test$
DECLARE v_affinity text;
BEGIN
  SELECT session_data #>> '{encounter,affinity}' INTO v_affinity
  FROM public.chat_sessions WHERE id='a9000000-0000-4000-8000-000000000001';
  IF v_affinity<>'48' THEN RAISE EXCEPTION 'subsequent Encounter session did not inherit updated shared affinity: %',v_affinity; END IF;
END
$test$;

\echo 'Encounter per-turn affinity, idempotency, shared/independent synchronization and session seeding passed.'
ROLLBACK;
