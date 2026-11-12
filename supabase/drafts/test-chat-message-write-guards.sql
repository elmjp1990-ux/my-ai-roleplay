-- Disposable-only integration tests for PR #226.
-- Run after loading the synthetic current-state schema and applying
-- 20261111130000_activate_chat_message_write_guards.sql.
-- All fixture writes are rolled back. Never run against hosted Supabase.

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.assert_rejected(
  p_sql text,
  p_expected_state text,
  p_label text
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_state text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    IF v_state = p_expected_state THEN
      RETURN;
    END IF;
    RAISE EXCEPTION '%: expected SQLSTATE %, got %', p_label, p_expected_state, v_state;
  END;
  RAISE EXCEPTION '%: statement unexpectedly succeeded', p_label;
END;
$$;

DO $$
DECLARE
  v_policy_count integer;
BEGIN
  SELECT count(*) INTO v_policy_count
  FROM pg_catalog.pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'chat_messages'
    AND cmd = 'INSERT'
    AND permissive = 'PERMISSIVE';

  IF v_policy_count <> 1 THEN
    RAISE EXCEPTION 'expected exactly one permissive chat_messages INSERT policy; got %', v_policy_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_policy p
    WHERE p.polrelid = 'public.chat_messages'::regclass
      AND p.polname = 'chat_messages_insert_own'
      AND pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) ILIKE '%role%'
      AND pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) ILIKE '%user%'
      AND pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) ILIKE '%account_is_active%'
      AND pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) ILIKE '%deleted_at%'
  ) THEN
    RAISE EXCEPTION 'chat_messages INSERT policy is missing its role/account/active-session gates';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgrelid = 'public.chat_messages'::regclass
      AND tgname = 'guard_chat_turn_assistant_update'
      AND tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'assistant UPDATE guard trigger is missing or disabled';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgrelid = 'public.chat_messages'::regclass
      AND tgname = 'guard_chat_message_created_at_update'
      AND tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'message created_at immutability trigger is missing or disabled';
  END IF;

  IF has_function_privilege('anon', 'public.guard_chat_turn_assistant_update()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.guard_chat_turn_assistant_update()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.guard_chat_turn_assistant_insert()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.guard_chat_turn_assistant_insert()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.guard_chat_message_created_at_update()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.guard_chat_message_created_at_update()', 'EXECUTE') THEN
    RAISE EXCEPTION 'browser roles must not execute trigger functions directly';
  END IF;

  IF (
    SELECT count(*)
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname IN ('guard_chat_turn_assistant_insert','guard_chat_turn_assistant_update')
      AND p.prosecdef
      AND 'search_path=""' = ANY(COALESCE(p.proconfig, ARRAY[]::text[]))
  ) <> 2 THEN
    RAISE EXCEPTION 'assistant write guards must remain SECURITY DEFINER with an empty search_path';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname='guard_chat_message_created_at_update'
      AND NOT p.prosecdef
      AND 'search_path=""' = ANY(COALESCE(p.proconfig, ARRAY[]::text[]))
  ) THEN
    RAISE EXCEPTION 'timestamp immutability guard must remain SECURITY INVOKER with an empty search_path';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.guard_chat_turn_assistant_update()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.guard_chat_turn_assistant_insert()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.guard_chat_message_created_at_update()', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role must retain trigger function EXECUTE privileges';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_indexes WHERE schemaname='public' AND indexname='chat_sessions_pkey')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_indexes WHERE schemaname='public' AND indexname='chat_turn_charges_expected_assistant_message_id_key')
     OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_indexes WHERE schemaname='public' AND indexname='idx_chat_messages_session_created') THEN
    RAISE EXCEPTION 'expected parent/charge/message lookup indexes are missing';
  END IF;
END;
$$;

-- Fixed synthetic identities. The enclosing transaction is always rolled back.
INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) VALUES
  ('11111111-1111-4111-8111-111111111111', 'authenticated', 'authenticated', 'write-guard-a@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('22222222-2222-4222-8222-222222222222', 'authenticated', 'authenticated', 'write-guard-b@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, now(), now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, handle, nickname)
VALUES
  ('11111111-1111-4111-8111-111111111111', 'write_guard_a', 'Write Guard A'),
  ('22222222-2222-4222-8222-222222222222', 'write_guard_b', 'Write Guard B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.chat_sessions (id, user_id, character_name, status, chat_mode)
VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '11111111-1111-4111-8111-111111111111', 'Synthetic A', 'active', 'story'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '22222222-2222-4222-8222-222222222222', 'Synthetic B', 'active', 'story'),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '11111111-1111-4111-8111-111111111111', 'Synthetic Deleted', 'active', 'story')
ON CONFLICT (id) DO NOTHING;

UPDATE public.chat_sessions
SET deleted_at = now()
WHERE id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

INSERT INTO public.account_deletion_requests (user_id)
VALUES ('22222222-2222-4222-8222-222222222222')
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO public.chat_messages (id, session_id, role, content)
VALUES
  ('a1000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'user', 'original user message'),
  ('a1000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'user', 'second turn user message'),
  ('a1000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'user', 'third turn user message'),
  ('b1000000-0000-4000-8000-000000000001', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'user', 'other user message')
ON CONFLICT (id) DO NOTHING;

-- Browser role: own active user messages are allowed; forged roles, foreign
-- sessions and deleted sessions are denied by RLS.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

INSERT INTO public.chat_messages (id, session_id, role, content)
VALUES ('a1000000-0000-4000-8000-000000000004', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'user', 'I1 allowed own user message');

SELECT pg_temp.assert_rejected(
  $query$INSERT INTO public.chat_messages (id, session_id, role, content)
    VALUES ('a1000000-0000-4000-8000-000000000005', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'assistant', 'forged')$query$,
  'P0001', 'I2 forged assistant role blocked by BEFORE INSERT guard'
);

SELECT pg_temp.assert_rejected(
  $query$INSERT INTO public.chat_messages (id, session_id, role, content)
    VALUES ('a1000000-0000-4000-8000-000000000006', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'system', 'forged system role')$query$,
  '42501', 'I2 system role blocked by INSERT RLS'
);

SELECT pg_temp.assert_rejected(
  $query$INSERT INTO public.chat_messages (id, session_id, role, content)
    VALUES ('a1000000-0000-4000-8000-000000000007', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'user', 'foreign session')$query$,
  '42501', 'I3 foreign session blocked by RLS'
);

SELECT pg_temp.assert_rejected(
  $query$INSERT INTO public.chat_messages (id, session_id, role, content)
    VALUES ('a1000000-0000-4000-8000-000000000008', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'user', 'deleted session')$query$,
  'P0001', 'I4 deleted session blocked by parent lifecycle trigger'
);

-- Pending account deletion must also freeze writes even when its session is active.
SELECT set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
SELECT set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
SELECT pg_temp.assert_rejected(
  $query$INSERT INTO public.chat_messages (id, session_id, role, content)
    VALUES ('b1000000-0000-4000-8000-000000000002', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'user', 'inactive account')$query$,
  '42501', 'I4 inactive account blocked by RLS'
);

-- Restore user A claims for the owner update checks.
SELECT set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

-- User content editing remains compatible; identity and role are immutable.
UPDATE public.chat_messages
SET content = 'edited user message'
WHERE id = 'a1000000-0000-4000-8000-000000000001';

SELECT pg_temp.assert_rejected(
  $query$UPDATE public.chat_messages
    SET created_at = created_at + interval '1 day'
    WHERE id = 'a1000000-0000-4000-8000-000000000001'$query$,
  'P0001', 'message created_at is immutable for the owner'
);

SELECT pg_temp.assert_rejected(
  $query$UPDATE public.chat_messages
    SET id = 'a1000000-0000-4000-8000-000000000099'
    WHERE id = 'a1000000-0000-4000-8000-000000000001'$query$,
  'P0001', 'U1 user message identity is immutable'
);

RESET ROLE;

-- Prepare three reserved turns. The assistant INSERT trigger must serialize
-- against the parent session and accept only the expected ID/session/state.
INSERT INTO public.chat_turn_charges (
  turn_id, user_id, session_id, user_message_id,
  expected_assistant_message_id, cost, silver_reserved, status
) VALUES
  ('d1000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'a1000000-0000-4000-8000-000000000001',
   'd2000000-0000-4000-8000-000000000001', 2, 2, 'reserved'),
  ('d1000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'a1000000-0000-4000-8000-000000000002',
   'd2000000-0000-4000-8000-000000000002', 2, 2, 'reserved'),
  ('d1000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'a1000000-0000-4000-8000-000000000003',
   'd2000000-0000-4000-8000-000000000003', 2, 2, 'settled');

SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);

SELECT pg_temp.assert_rejected(
  $query$INSERT INTO public.chat_messages (id, session_id, role, content)
    VALUES ('d2000000-0000-4000-8000-000000000099', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'assistant', 'no charge')$query$,
  'P0001', 'I5 assistant insert without a charge is blocked'
);

SELECT pg_temp.assert_rejected(
  $query$INSERT INTO public.chat_messages (id, session_id, role, content)
    VALUES ('d2000000-0000-4000-8000-000000000001', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'assistant', 'wrong session')$query$,
  'P0001', 'I7 assistant insert into wrong session is blocked'
);

SELECT pg_temp.assert_rejected(
  $query$INSERT INTO public.chat_messages (id, session_id, role, content)
    VALUES ('d2000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'assistant', '   ')$query$,
  'P0001', 'I7 empty assistant content is blocked'
);

SELECT pg_temp.assert_rejected(
  $query$INSERT INTO public.chat_messages (id, session_id, role, content)
    VALUES ('d2000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'assistant', 'already settled')$query$,
  'P0001', 'I7 settled charge cannot create a new assistant reply'
);

INSERT INTO public.chat_messages (id, session_id, role, content)
VALUES
  ('d2000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'assistant', 'reserved assistant reply'),
  ('d2000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'assistant', 'settled assistant reply');

RESET ROLE;

UPDATE public.chat_turn_charges
SET status='settled', assistant_message_id='d2000000-0000-4000-8000-000000000002', settled_at=now()
WHERE turn_id='d1000000-0000-4000-8000-000000000002';

-- Owner may not edit/hide an unresolved assistant reply. The version trigger
-- runs in the same statement transaction, so a rejected edit must leave no
-- version-history side effect.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

SELECT pg_temp.assert_rejected(
  $query$UPDATE public.chat_messages SET role='user'
    WHERE id='d2000000-0000-4000-8000-000000000001'$query$,
  'P0001', 'U1 assistant message role is immutable'
);

SELECT pg_temp.assert_rejected(
  $query$UPDATE public.chat_messages
    SET session_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    WHERE id='d2000000-0000-4000-8000-000000000001'$query$,
  'P0001', 'U1 assistant message session identity is immutable'
);

SELECT pg_temp.assert_rejected(
  $query$UPDATE public.chat_messages SET content='forged edit'
    WHERE id='d2000000-0000-4000-8000-000000000001'$query$,
  'P0001', 'U3 unresolved assistant content edit is blocked'
);

SELECT pg_temp.assert_rejected(
  $query$UPDATE public.chat_messages SET deleted_at=now()
    WHERE id='d2000000-0000-4000-8000-000000000001'$query$,
  'P0001', 'U5 unresolved assistant soft delete is blocked'
);

-- A settled assistant reply retains the existing edit/version behavior.
UPDATE public.chat_messages
SET content='edited settled assistant reply'
WHERE id='d2000000-0000-4000-8000-000000000002';

DO $body$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_message_versions
    WHERE message_id='d2000000-0000-4000-8000-000000000002'
      AND content='settled assistant reply'
  ) THEN
    RAISE EXCEPTION 'U4 settled assistant edit did not preserve the previous version';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.chat_message_versions
    WHERE message_id='d2000000-0000-4000-8000-000000000001'
  ) THEN
    RAISE EXCEPTION 'rejected unresolved assistant edits left version-history side effects';
  END IF;
END;
$body$;

-- Remove user B's pending deletion marker only inside this disposable
-- transaction, then test the ownership boundary independently.
RESET ROLE;
DELETE FROM public.account_deletion_requests
WHERE user_id='22222222-2222-4222-8222-222222222222';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
UPDATE public.chat_messages
SET content='unauthorized edit'
WHERE id='a1000000-0000-4000-8000-000000000001';

-- Inspect as the database owner so the assertion is not hidden by user B's
-- SELECT RLS policy. The UPDATE above ran as user B.
RESET ROLE;
DO $body$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_messages
    WHERE id='a1000000-0000-4000-8000-000000000001'
      AND content='edited user message'
  ) THEN
    RAISE EXCEPTION 'U7 another authenticated user changed the owner message';
  END IF;
END;
$body$;

-- Return to the owner to confirm settled replies can still be soft-deleted.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
SELECT set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
UPDATE public.chat_messages
SET deleted_at=now()
WHERE id='d2000000-0000-4000-8000-000000000002';

RESET ROLE;

-- Service role without the purge-worker marker must still be unable to change
-- role or identity while the parent session is active.
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SELECT set_config('app.chat_purge_worker', '', true);

SELECT pg_temp.assert_rejected(
  $query$UPDATE public.chat_messages SET created_at=created_at + interval '1 day'
    WHERE id='a1000000-0000-4000-8000-000000000002'$query$,
  'P0001', 'service role cannot rewrite message chronology'
);

SELECT pg_temp.assert_rejected(
  $query$UPDATE public.chat_messages SET role='assistant'
    WHERE id='a1000000-0000-4000-8000-000000000002'$query$,
  'P0001', 'P2 service role without purge marker cannot change role'
);

RESET ROLE;
UPDATE public.chat_sessions
SET deleted_at=now()
WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

-- Only the authorized service-role purge path may bypass content/soft-delete
-- guards after the parent is deleted. It must not create message versions.
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SELECT set_config('app.chat_purge_worker', 'on', true);

UPDATE public.chat_messages
SET content='', deleted_at=now()
WHERE id='d2000000-0000-4000-8000-000000000001';

DO $$
DECLARE
  v_charge_count integer;
  v_wallet_tx_count integer;
BEGIN
  SELECT count(*) INTO v_charge_count
  FROM public.chat_turn_charges
  WHERE turn_id IN (
    'd1000000-0000-4000-8000-000000000001',
    'd1000000-0000-4000-8000-000000000002',
    'd1000000-0000-4000-8000-000000000003'
  );
  IF v_charge_count <> 3 THEN RAISE EXCEPTION 'charge rows unexpectedly changed'; END IF;

  SELECT count(*) INTO v_wallet_tx_count
  FROM public.wallet_transactions
  WHERE user_id IN (
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222'
  );
  IF v_wallet_tx_count <> 0 THEN RAISE EXCEPTION 'write-guard tests unexpectedly changed wallet ledger'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.chat_message_versions
    WHERE message_id='d2000000-0000-4000-8000-000000000001'
  ) THEN
    RAISE EXCEPTION 'purge-worker path unexpectedly created message versions';
  END IF;
END;
$$;

ROLLBACK;
