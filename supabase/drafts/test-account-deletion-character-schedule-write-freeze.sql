-- Disposable behavior test: pending account deletion freezes character schedules.
-- Run after 20261104200200 in the rollback-only release migration replay.
INSERT INTO auth.users (id)
VALUES ('10000000-0000-4000-8000-000000000092')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, handle, nickname)
VALUES ('10000000-0000-4000-8000-000000000092', 'pr200-schedule-freeze', 'Schedule Freeze')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.characters (id, author_id, name, visibility, review_status, rights_confirmed)
VALUES (
  '20000000-0000-4000-8000-000000000092',
  '10000000-0000-4000-8000-000000000092',
  'Schedule freeze fixture',
  'private',
  'draft',
  true
);

INSERT INTO public.character_schedules (
  id, character_id, weekday, day_type, start_time, end_time, location_key, activity
)
VALUES (
  '40000000-0000-4000-8000-000000000092',
  '20000000-0000-4000-8000-000000000092',
  1, 'any', '09:00', '10:00', 'cafe', 'Before deletion request'
);

INSERT INTO public.account_deletion_requests (user_id, requested_at, scheduled_for)
VALUES (
  '10000000-0000-4000-8000-000000000092',
  pg_catalog.statement_timestamp(),
  pg_catalog.statement_timestamp() + interval '5 minutes'
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000092', true);
SELECT pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
SELECT pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"10000000-0000-4000-8000-000000000092","role":"authenticated"}',
  true
);

DO $test$
DECLARE
  v_count integer;
  v_rpc_blocked boolean := false;
  v_insert_blocked boolean := false;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.character_schedules
  WHERE id = '40000000-0000-4000-8000-000000000092';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'pending_account_must_not_read_character_schedules';
  END IF;

  BEGIN
    PERFORM public.save_character_schedules(
      '20000000-0000-4000-8000-000000000092',
      '[{"weekday":1,"day_type":"any","start_time":"10:00","end_time":"11:00","location_key":"cafe","activity":"Blocked update"}]'::jsonb
    );
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_rpc_blocked := true;
  END;
  IF NOT v_rpc_blocked THEN
    RAISE EXCEPTION 'pending_account_schedule_rpc_must_be_blocked';
  END IF;

  BEGIN
    INSERT INTO public.character_schedules (
      id, character_id, weekday, day_type, start_time, end_time, location_key, activity
    ) VALUES (
      '40000000-0000-4000-8000-000000000093',
      '20000000-0000-4000-8000-000000000092',
      2, 'any', '11:00', '12:00', 'cafe', 'Blocked insert'
    );
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_insert_blocked := true;
  END;
  IF NOT v_insert_blocked THEN
    RAISE EXCEPTION 'pending_account_schedule_insert_must_be_blocked';
  END IF;

  UPDATE public.character_schedules
  SET activity = 'Blocked direct update'
  WHERE id = '40000000-0000-4000-8000-000000000092';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'pending_account_schedule_direct_update_must_be_blocked';
  END IF;

  DELETE FROM public.character_schedules
  WHERE id = '40000000-0000-4000-8000-000000000092';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'pending_account_schedule_direct_delete_must_be_blocked';
  END IF;
END;
$test$;

RESET ROLE;

DO $verify$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.character_schedules
    WHERE id = '40000000-0000-4000-8000-000000000092'
      AND activity = 'Before deletion request'
  ) THEN
    RAISE EXCEPTION 'pending_account_schedule_write_attempts_must_not_change_saved_data';
  END IF;
END;
$verify$;

