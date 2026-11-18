-- DRAFT TEST ONLY: new Encounter sessions preserve relationship state but do not
-- select or persist pre-generated greeting text. Run after the compact schedule
-- migration against the disposable local Supabase database only.

BEGIN;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, created_at, updated_at
) VALUES (
  '00000000-0000-4000-8000-000000000030',
  'authenticated', 'authenticated',
  'encounter-discovery-smoke@example.invalid', '',
  clock_timestamp(), clock_timestamp()
);

INSERT INTO public.profiles (id, handle, nickname)
VALUES (
  '00000000-0000-4000-8000-000000000030',
  'encounter-discovery-smoke',
  'Encounter discovery 測試'
);

INSERT INTO public.characters (
  id, author_id, name, visibility, review_status, rights_confirmed
) VALUES (
  '00000000-0000-4000-8000-000000000031',
  '00000000-0000-4000-8000-000000000030',
  'Encounter discovery 測試角色', 'public', 'approved', true
);

INSERT INTO public.encounter_character_state (
  user_id, character_id, affinity, relationship_stage, first_met_at, last_interaction_at
) VALUES (
  '00000000-0000-4000-8000-000000000030',
  '00000000-0000-4000-8000-000000000031',
  45, 'close', clock_timestamp(), clock_timestamp()
);

-- A legacy greeting pool may still exist during migration. New sessions must
-- ignore it; the first reply is generated only after the player's first send.
INSERT INTO public.encounter_character_greeting_pools (
  character_id, source_hash, greeting_pools
) VALUES (
  '00000000-0000-4000-8000-000000000031',
  '0123456789abcdef0123456789abcdef',
  jsonb_build_object('close', jsonb_build_array(repeat('舊招呼', 80)))
);

SET LOCAL ROLE service_role;
SET LOCAL request.jwt.claim.role = 'service_role';

DO $encounter_discovery_session_smoke$
DECLARE
  v_session jsonb;
  v_stage text;
  v_affinity integer;
  v_stage_session jsonb;
BEGIN
  v_session := public.create_encounter_session_with_lifecycle(
    '00000000-0000-4000-8000-000000000032',
    '00000000-0000-4000-8000-000000000030',
    '00000000-0000-4000-8000-000000000031',
    'Encounter discovery 測試角色',
    jsonb_build_object(
      'name', 'Encounter discovery 測試角色',
      'encounterGreeting', repeat('不應保留的舊招呼', 20),
      'encounterGreetingId', 'legacy:should-not-survive'
    ),
    '{"activity":"測試場景"}'::jsonb,
    'cafe',
    clock_timestamp(),
    clock_timestamp() + interval '1 hour'
  );

  IF v_session->'session_data'->'encounter'->>'relationshipStage' <> 'close'
     OR (v_session->'session_data'->'encounter'->>'affinity')::integer <> 45 THEN
    RAISE EXCEPTION 'new Encounter session did not inherit current affinity and relationship stage';
  END IF;
  IF v_session->'character_snapshot' ? 'encounterGreeting'
     OR v_session->'character_snapshot' ? 'encounterGreetingId'
     OR v_session->'session_data'->'encounter' ? 'greetingText'
     OR v_session->'session_data'->'encounter' ? 'greetingId' THEN
    RAISE EXCEPTION 'new Encounter session retained a pre-generated greeting';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.encounter_character_greeting_history
    WHERE user_id = '00000000-0000-4000-8000-000000000030'
      AND character_id = '00000000-0000-4000-8000-000000000031'
  ) THEN
    RAISE EXCEPTION 'new Encounter session wrote legacy greeting rotation history';
  END IF;

  UPDATE public.encounter_character_state
  SET affinity = 85, relationship_stage = 'special'
  WHERE user_id = '00000000-0000-4000-8000-000000000030'
    AND character_id = '00000000-0000-4000-8000-000000000031';

  v_session := public.create_encounter_session_with_lifecycle(
    '00000000-0000-4000-8000-000000000033',
    '00000000-0000-4000-8000-000000000030',
    '00000000-0000-4000-8000-000000000031',
    'Encounter discovery 測試角色',
    jsonb_build_object('name', 'Encounter discovery 測試角色'),
    '{"activity":"測試場景"}'::jsonb,
    'cafe',
    clock_timestamp(),
    clock_timestamp() + interval '1 hour'
  );
  IF v_session->'session_data'->'encounter'->>'relationshipStage' <> 'special'
     OR (v_session->'session_data'->'encounter'->>'affinity')::integer <> 85 THEN
    RAISE EXCEPTION 'new Encounter session did not load the latest affinity';
  END IF;

  FOREACH v_stage IN ARRAY ARRAY[
    'hostile','dislike','wary','first_meeting',
    'acquaintance','close','intimate','special'
  ] LOOP
    UPDATE public.encounter_character_state
    SET relationship_stage = v_stage
    WHERE user_id = '00000000-0000-4000-8000-000000000030'
      AND character_id = '00000000-0000-4000-8000-000000000031';

    v_stage_session := public.create_encounter_session_with_lifecycle(
      gen_random_uuid(),
      '00000000-0000-4000-8000-000000000030',
      '00000000-0000-4000-8000-000000000031',
      'Encounter discovery 測試角色',
      jsonb_build_object('name', 'Encounter discovery 測試角色'),
      '{"activity":"階段狀態測試"}'::jsonb,
      'cafe',
      clock_timestamp(),
      clock_timestamp() + interval '1 hour'
    );

    IF v_stage_session->'session_data'->'encounter'->>'relationshipStage' <> v_stage
       OR (v_stage_session->'session_data'->'encounter'->>'affinity')::integer <> 85
       OR v_stage_session->'character_snapshot' ? 'encounterGreeting' THEN
      RAISE EXCEPTION 'relationship stage % or affinity was not preserved without a greeting', v_stage;
    END IF;
  END LOOP;
END;
$encounter_discovery_session_smoke$;

RESET ROLE;
ROLLBACK;
