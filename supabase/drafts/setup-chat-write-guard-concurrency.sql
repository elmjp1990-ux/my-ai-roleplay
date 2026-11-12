-- Disposable concurrency fixtures only. The CI database is discarded after the run.
INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) VALUES (
  '33333333-3333-4333-8333-333333333333',
  'authenticated', 'authenticated', 'write-guard-race@example.invalid', '',
  now(), '{}'::jsonb, '{}'::jsonb, now(), now()
);

INSERT INTO public.profiles (id, handle, nickname)
VALUES ('33333333-3333-4333-8333-333333333333', 'write_guard_race', 'Write Guard Race')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.chat_sessions (id, user_id, character_name, status, chat_mode)
VALUES
  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1', '33333333-3333-4333-8333-333333333333', 'Delete wins', 'active', 'story'),
  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2', '33333333-3333-4333-8333-333333333333', 'Writer wins', 'active', 'story');

INSERT INTO public.chat_messages (id, session_id, role, content)
VALUES
  ('e1000000-0000-4000-8000-000000000001', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1', 'user', 'delete race'),
  ('e1000000-0000-4000-8000-000000000002', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2', 'user', 'writer race');

INSERT INTO public.chat_turn_charges (
  turn_id, user_id, session_id, user_message_id,
  expected_assistant_message_id, cost, silver_reserved, status
) VALUES
  ('e2000000-0000-4000-8000-000000000001', '33333333-3333-4333-8333-333333333333',
   'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1', 'e1000000-0000-4000-8000-000000000001',
   'e3000000-0000-4000-8000-000000000001', 2, 2, 'reserved'),
  ('e2000000-0000-4000-8000-000000000002', '33333333-3333-4333-8333-333333333333',
   'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2', 'e1000000-0000-4000-8000-000000000002',
   'e3000000-0000-4000-8000-000000000002', 2, 2, 'reserved');
