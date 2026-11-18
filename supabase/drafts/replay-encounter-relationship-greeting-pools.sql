-- DRAFT TEST ONLY: relationship-stage greeting pool selection and per-player anti-repeat.
-- Run after encounter-schedule-pipeline.sql and encounter-relationship-greeting-pools.sql
-- against the disposable local synthetic Supabase database only.

BEGIN;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, created_at, updated_at
) VALUES (
  '00000000-0000-4000-8000-000000000030',
  'authenticated', 'authenticated',
  'encounter-greeting-smoke@example.invalid', '',
  clock_timestamp(), clock_timestamp()
);

INSERT INTO public.profiles (id, handle, nickname)
VALUES (
  '00000000-0000-4000-8000-000000000030',
  'encounter-greeting-smoke',
  'Encounter greeting 測試'
);

INSERT INTO public.characters (
  id, author_id, name, visibility, review_status, rights_confirmed
) VALUES (
  '00000000-0000-4000-8000-000000000031',
  '00000000-0000-4000-8000-000000000030',
  'Encounter greeting 測試角色', 'public', 'approved', true
);

INSERT INTO public.encounter_character_state (
  user_id, character_id, affinity, relationship_stage, first_met_at, last_interaction_at
) VALUES (
  '00000000-0000-4000-8000-000000000030',
  '00000000-0000-4000-8000-000000000031',
  45, 'close', clock_timestamp(), clock_timestamp()
);

INSERT INTO public.encounter_character_greeting_pools (
  character_id, source_hash, greeting_pools
) VALUES (
  '00000000-0000-4000-8000-000000000031',
  '0123456789abcdef0123456789abcdef',
  jsonb_build_object(
    'hostile', jsonb_build_array(repeat('H',150)||'1', repeat('H',150)||'2', repeat('H',150)||'3'),
    'dislike', jsonb_build_array(repeat('D',150)||'1', repeat('D',150)||'2', repeat('D',150)||'3'),
    'wary', jsonb_build_array(repeat('W',150)||'1', repeat('W',150)||'2', repeat('W',150)||'3'),
    'first_meeting', jsonb_build_array(repeat('F',150)||'1', repeat('F',150)||'2', repeat('F',150)||'3'),
    'acquaintance', jsonb_build_array(repeat('A',150)||'1', repeat('A',150)||'2', repeat('A',150)||'3'),
    'close', jsonb_build_array(repeat('C',150)||'1', repeat('C',150)||'2', repeat('C',150)||'3'),
    'intimate', jsonb_build_array(repeat('I',150)||'1', repeat('I',150)||'2', repeat('I',150)||'3'),
    'special', jsonb_build_array(repeat('S',150)||'1', repeat('S',150)||'2', repeat('S',150)||'3')
  )
);

SET LOCAL ROLE service_role;
SET LOCAL request.jwt.claim.role = 'service_role';

DO $relationship_greeting_selection_smoke$
DECLARE
  v_first jsonb;
  v_second jsonb;
  v_special jsonb;
  v_first_id text;
  v_second_id text;
  v_first_text text;
  v_second_text text;
  v_special_text text;
  v_stage text;
  v_expected_prefix text;
  v_stage_session jsonb;
  v_stage_text text;
BEGIN
  v_first := public.create_encounter_session_with_lifecycle(
    '00000000-0000-4000-8000-000000000032',
    '00000000-0000-4000-8000-000000000030',
    '00000000-0000-4000-8000-000000000031',
    'Encounter greeting 測試角色',
    jsonb_build_object('name','Encounter greeting 測試角色','encounterGreeting',repeat('L',150)),
    '{"activity":"測試場景"}'::jsonb,
    'cafe',
    clock_timestamp(),
    clock_timestamp() + interval '1 hour'
  );
  v_second := public.create_encounter_session_with_lifecycle(
    '00000000-0000-4000-8000-000000000033',
    '00000000-0000-4000-8000-000000000030',
    '00000000-0000-4000-8000-000000000031',
    'Encounter greeting 測試角色',
    jsonb_build_object('name','Encounter greeting 測試角色','encounterGreeting',repeat('L',150)),
    '{"activity":"測試場景"}'::jsonb,
    'cafe',
    clock_timestamp(),
    clock_timestamp() + interval '1 hour'
  );

  v_first_id := v_first->'character_snapshot'->>'encounterGreetingId';
  v_second_id := v_second->'character_snapshot'->>'encounterGreetingId';
  v_first_text := v_first->'character_snapshot'->>'encounterGreeting';
  v_second_text := v_second->'character_snapshot'->>'encounterGreeting';

  IF v_first->'session_data'->'encounter'->>'relationshipStage' <> 'close'
     OR (v_first->'session_data'->'encounter'->>'affinity')::integer <> 45 THEN
    RAISE EXCEPTION 'Encounter session did not inherit the current affinity and relationship stage';
  END IF;
  IF v_first_id IS NULL OR v_second_id IS NULL OR v_first_id = v_second_id THEN
    RAISE EXCEPTION 'consecutive sessions repeated the same opening greeting';
  END IF;
  IF v_first_text NOT LIKE 'C%' OR v_second_text NOT LIKE 'C%' THEN
    RAISE EXCEPTION 'close relationship did not select from its own greeting pool';
  END IF;
  IF v_first_text <> v_first->'session_data'->'encounter'->>'greetingText'
     OR v_second_text <> v_second->'session_data'->'encounter'->>'greetingText' THEN
    RAISE EXCEPTION 'selected greeting was not persisted consistently in the session snapshot';
  END IF;

  UPDATE public.encounter_character_state
  SET affinity = 85, relationship_stage = 'special'
  WHERE user_id = '00000000-0000-4000-8000-000000000030'
    AND character_id = '00000000-0000-4000-8000-000000000031';

  v_special := public.create_encounter_session_with_lifecycle(
    '00000000-0000-4000-8000-000000000034',
    '00000000-0000-4000-8000-000000000030',
    '00000000-0000-4000-8000-000000000031',
    'Encounter greeting 測試角色',
    jsonb_build_object('name','Encounter greeting 測試角色','encounterGreeting',repeat('L',150)),
    '{"activity":"測試場景"}'::jsonb,
    'cafe',
    clock_timestamp(),
    clock_timestamp() + interval '1 hour'
  );
  v_special_text := v_special->'character_snapshot'->>'encounterGreeting';
  IF v_special->'session_data'->'encounter'->>'relationshipStage' <> 'special'
     OR v_special_text NOT LIKE 'S%' THEN
    RAISE EXCEPTION 'special relationship did not select from the special greeting pool';
  END IF;

  -- Verify every supported relationship stage reads only its own pool.
  FOREACH v_stage IN ARRAY ARRAY[
    'hostile','dislike','wary','first_meeting',
    'acquaintance','close','intimate','special'
  ] LOOP
    UPDATE public.encounter_character_state
    SET relationship_stage = v_stage
    WHERE user_id = '00000000-0000-4000-8000-000000000030'
      AND character_id = '00000000-0000-4000-8000-000000000031';

    SELECT CASE v_stage
      WHEN 'hostile' THEN 'H'
      WHEN 'dislike' THEN 'D'
      WHEN 'wary' THEN 'W'
      WHEN 'first_meeting' THEN 'F'
      WHEN 'acquaintance' THEN 'A'
      WHEN 'close' THEN 'C'
      WHEN 'intimate' THEN 'I'
      WHEN 'special' THEN 'S'
    END INTO v_expected_prefix;

    v_stage_session := public.create_encounter_session_with_lifecycle(
      gen_random_uuid(),
      '00000000-0000-4000-8000-000000000030',
      '00000000-0000-4000-8000-000000000031',
      'Encounter greeting 測試角色',
      jsonb_build_object('name','Encounter greeting 測試角色','encounterGreeting',repeat('L',150)),
      '{"activity":"階段池測試"}'::jsonb,
      'cafe',
      clock_timestamp(),
      clock_timestamp() + interval '1 hour'
    );
    v_stage_text := v_stage_session->'character_snapshot'->>'encounterGreeting';

    IF v_stage_session->'session_data'->'encounter'->>'relationshipStage' <> v_stage
       OR left(v_stage_text,1) <> v_expected_prefix THEN
      RAISE EXCEPTION 'relationship stage % selected the wrong greeting pool', v_stage;
    END IF;
  END LOOP;
END;
$relationship_greeting_selection_smoke$;

RESET ROLE;
ROLLBACK;
