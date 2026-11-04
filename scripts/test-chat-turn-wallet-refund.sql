-- Offline wallet state-machine regression tests for Story chat turns.
-- Run only against a disposable PostgreSQL database; this script rolls back all setup/data.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE public.wallet_accounts (
  user_id uuid PRIMARY KEY,
  silver_coins integer NOT NULL DEFAULT 0,
  diamonds integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.wallet_transactions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL,
  currency_type text NOT NULL,
  amount integer NOT NULL,
  biz_type text NOT NULL,
  reference_id text
);
CREATE TABLE public.chat_turn_charges (
  turn_id uuid PRIMARY KEY,
  user_id uuid NOT NULL,
  session_id uuid NOT NULL,
  user_message_id uuid NOT NULL,
  expected_assistant_message_id uuid NOT NULL,
  assistant_message_id uuid,
  cost integer NOT NULL,
  status text NOT NULL,
  silver_reserved integer NOT NULL DEFAULT 0,
  diamonds_reserved integer NOT NULL DEFAULT 0,
  failure_code text,
  reserved_at timestamptz,
  settled_at timestamptz,
  refunded_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.chat_turn_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  turn_id uuid NOT NULL,
  user_id uuid NOT NULL,
  event_type text NOT NULL,
  stage text NOT NULL,
  error_code text
);
CREATE TABLE public.chat_sessions (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL,
  deleted_at timestamptz
);
CREATE TABLE public.chat_messages (
  id uuid PRIMARY KEY,
  session_id uuid NOT NULL,
  role text NOT NULL,
  content text NOT NULL,
  deleted_at timestamptz
);
CREATE TABLE public.account_deletion_requests (user_id uuid PRIMARY KEY);

\ir ../supabase/migrations/20261015133300_chat_turn_transaction_functions.sql
\ir ../supabase/migrations/20261015145637_fix_reserve_chat_turn_conflict_target.sql
\ir ../supabase/migrations/20261015134109_chat_turn_ledger_idempotency.sql
DO $roles$ DECLARE r text; BEGIN FOREACH r IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('CREATE ROLE %I',r); END IF; END LOOP; END $roles$;
\ir ../supabase/migrations/20261104130000_reconcile_stale_story_chat_turns.sql

-- Silver-only: exact original currency is restored; duplicate refund is idempotent.
DO $test$
DECLARE r record; n integer; s integer; d integer;
BEGIN
  INSERT INTO public.wallet_accounts(user_id,silver_coins,diamonds)
  VALUES ('10000000-0000-4000-8000-000000000001', 7, 0);
  INSERT INTO public.chat_sessions(id,user_id)
  VALUES ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001');
  INSERT INTO public.chat_messages(id,session_id,role,content)
  VALUES ('30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','user','hello');
  SELECT * INTO r FROM public.reserve_chat_turn(
    '10000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001',
    '50000000-0000-4000-8000-000000000001');
  IF r.status <> 'reserved' OR r.silver_reserved <> 2 OR r.diamonds_reserved <> 0 THEN
    RAISE EXCEPTION 'silver_only_reservation_failed: %', row_to_json(r);
  END IF;
  SELECT * INTO r FROM public.reserve_chat_turn(
    '10000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001',
    '50000000-0000-4000-8000-000000000001');
  IF r.status <> 'reserved' THEN RAISE EXCEPTION 'duplicate_reservation_not_idempotent'; END IF;
  SELECT * INTO r FROM public.refund_chat_turn(
    '10000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001',
    '50000000-0000-4000-8000-000000000001','test_silver_refund');
  SELECT * INTO r FROM public.refund_chat_turn(
    '10000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001',
    '50000000-0000-4000-8000-000000000001','duplicate_refund');
  SELECT silver_coins, diamonds INTO s,d FROM public.wallet_accounts
    WHERE user_id='10000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO n FROM public.wallet_transactions
    WHERE user_id='10000000-0000-4000-8000-000000000001'
      AND biz_type='chat_turn_refund' AND reference_id='40000000-0000-4000-8000-000000000001';
  IF s <> 7 OR d <> 0 OR n <> 1 THEN
    RAISE EXCEPTION 'silver_refund_not_exact_or_idempotent: silver %, diamonds %, refund_rows %',s,d,n;
  END IF;
END
$test$;

-- Diamond-only: no silver is fabricated and only the original diamonds return.
DO $test$
DECLARE r record; s integer; d integer;
BEGIN
  INSERT INTO public.wallet_accounts(user_id,silver_coins,diamonds)
  VALUES ('10000000-0000-4000-8000-000000000002', 0, 5);
  INSERT INTO public.chat_sessions(id,user_id)
  VALUES ('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002');
  INSERT INTO public.chat_messages(id,session_id,role,content)
  VALUES ('30000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000002','user','hello');
  SELECT * INTO r FROM public.reserve_chat_turn(
    '10000000-0000-4000-8000-000000000002','40000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000002',
    '50000000-0000-4000-8000-000000000002');
  IF r.status <> 'reserved' OR r.silver_reserved <> 0 OR r.diamonds_reserved <> 2 THEN
    RAISE EXCEPTION 'diamond_only_reservation_failed: %', row_to_json(r);
  END IF;
  PERFORM * FROM public.refund_chat_turn(
    '10000000-0000-4000-8000-000000000002','40000000-0000-4000-8000-000000000002',
    '50000000-0000-4000-8000-000000000002','test_diamond_refund');
  SELECT silver_coins, diamonds INTO s,d FROM public.wallet_accounts
    WHERE user_id='10000000-0000-4000-8000-000000000002';
  IF s <> 0 OR d <> 5 THEN
    RAISE EXCEPTION 'diamond_refund_not_exact: silver %, diamonds %',s,d;
  END IF;
END
$test$;

-- Mixed balance: silver is spent first, then diamonds; refund restores that split.
DO $test$
DECLARE r record; s integer; d integer;
BEGIN
  INSERT INTO public.wallet_accounts(user_id,silver_coins,diamonds)
  VALUES ('10000000-0000-4000-8000-000000000003', 1, 4);
  INSERT INTO public.chat_sessions(id,user_id)
  VALUES ('20000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000003');
  INSERT INTO public.chat_messages(id,session_id,role,content)
  VALUES ('30000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000003','user','hello');
  SELECT * INTO r FROM public.reserve_chat_turn(
    '10000000-0000-4000-8000-000000000003','40000000-0000-4000-8000-000000000003',
    '20000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000003',
    '50000000-0000-4000-8000-000000000003');
  IF r.silver_reserved <> 1 OR r.diamonds_reserved <> 1 THEN
    RAISE EXCEPTION 'mixed_reservation_split_failed: %', row_to_json(r);
  END IF;
  PERFORM * FROM public.refund_chat_turn(
    '10000000-0000-4000-8000-000000000003','40000000-0000-4000-8000-000000000003',
    '50000000-0000-4000-8000-000000000003','test_mixed_refund');
  SELECT silver_coins, diamonds INTO s,d FROM public.wallet_accounts
    WHERE user_id='10000000-0000-4000-8000-000000000003';
  IF s <> 1 OR d <> 4 THEN
    RAISE EXCEPTION 'mixed_refund_not_exact: silver %, diamonds %',s,d;
  END IF;
END
$test$;

-- Confirmed retry (e.g. 429/empty output): release the claim, retry the same turn,
-- and eventually settle exactly one original reservation.
DO $test$
DECLARE r record; s integer; d integer; n integer;
BEGIN
  INSERT INTO public.wallet_accounts(user_id,silver_coins,diamonds)
  VALUES ('10000000-0000-4000-8000-000000000004', 4, 3);
  INSERT INTO public.chat_sessions(id,user_id)
  VALUES ('20000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000004');
  INSERT INTO public.chat_messages(id,session_id,role,content)
  VALUES ('30000000-0000-4000-8000-000000000004','20000000-0000-4000-8000-000000000004','user','hello');
  SELECT * INTO r FROM public.reserve_chat_turn(
    '10000000-0000-4000-8000-000000000004','40000000-0000-4000-8000-000000000004',
    '20000000-0000-4000-8000-000000000004','30000000-0000-4000-8000-000000000004',
    '50000000-0000-4000-8000-000000000004');
  UPDATE public.chat_turn_charges SET status='needs_reconciliation',
    failure_code='provider_generation_in_progress'
    WHERE turn_id='40000000-0000-4000-8000-000000000004';
  UPDATE public.chat_turn_charges SET status='reserved',failure_code=NULL
    WHERE turn_id='40000000-0000-4000-8000-000000000004'
      AND status='needs_reconciliation' AND failure_code='provider_generation_in_progress';
  SELECT * INTO r FROM public.reserve_chat_turn(
    '10000000-0000-4000-8000-000000000004','40000000-0000-4000-8000-000000000004',
    '20000000-0000-4000-8000-000000000004','30000000-0000-4000-8000-000000000004',
    '50000000-0000-4000-8000-000000000004');
  IF r.status <> 'reserved' THEN RAISE EXCEPTION 'retry_lost_reservation'; END IF;
  INSERT INTO public.chat_messages(id,session_id,role,content)
  VALUES ('50000000-0000-4000-8000-000000000004','20000000-0000-4000-8000-000000000004','assistant','reply');
  IF public.settle_chat_turn(
    '10000000-0000-4000-8000-000000000004','40000000-0000-4000-8000-000000000004',
    '50000000-0000-4000-8000-000000000004') <> 'settled' THEN
    RAISE EXCEPTION 'retry_settlement_failed';
  END IF;
  SELECT silver_coins, diamonds INTO s,d FROM public.wallet_accounts
    WHERE user_id='10000000-0000-4000-8000-000000000004';
  SELECT count(*) INTO n FROM public.wallet_transactions
    WHERE user_id='10000000-0000-4000-8000-000000000004' AND biz_type='chat_turn_charge';
  IF s <> 2 OR d <> 3 OR n <> 1 THEN
    RAISE EXCEPTION 'retry_double_charged_or_wrong_balance: silver %, diamonds %, debit_rows %',s,d,n;
  END IF;
END
$test$;

-- Unknown provider outcome stays locked; late durable reply settles the same charge.
DO $test$
DECLARE r record; n integer;
BEGIN
  INSERT INTO public.wallet_accounts(user_id,silver_coins,diamonds)
  VALUES ('10000000-0000-4000-8000-000000000005', 3, 2);
  INSERT INTO public.chat_sessions(id,user_id)
  VALUES ('20000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000005');
  INSERT INTO public.chat_messages(id,session_id,role,content)
  VALUES ('30000000-0000-4000-8000-000000000005','20000000-0000-4000-8000-000000000005','user','hello');
  SELECT * INTO r FROM public.reserve_chat_turn(
    '10000000-0000-4000-8000-000000000005','40000000-0000-4000-8000-000000000005',
    '20000000-0000-4000-8000-000000000005','30000000-0000-4000-8000-000000000005',
    '50000000-0000-4000-8000-000000000005');
  UPDATE public.chat_turn_charges SET status='needs_reconciliation',failure_code='provider_timeout'
    WHERE turn_id='40000000-0000-4000-8000-000000000005';
  SELECT * INTO r FROM public.reserve_chat_turn(
    '10000000-0000-4000-8000-000000000005','40000000-0000-4000-8000-000000000005',
    '20000000-0000-4000-8000-000000000005','30000000-0000-4000-8000-000000000005',
    '50000000-0000-4000-8000-000000000005');
  IF r.status <> 'needs_reconciliation' THEN
    RAISE EXCEPTION 'unknown_outcome_was_retried_unsafely: %',row_to_json(r);
  END IF;
  INSERT INTO public.chat_messages(id,session_id,role,content)
  VALUES ('50000000-0000-4000-8000-000000000005','20000000-0000-4000-8000-000000000005','assistant','late reply');
  BEGIN
    PERFORM * FROM public.refund_chat_turn(
      '10000000-0000-4000-8000-000000000005','40000000-0000-4000-8000-000000000005',
      '50000000-0000-4000-8000-000000000005','must_not_refund_persisted_reply');
    RAISE EXCEPTION 'persisted_reply_was_refunded_before_settlement';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'persisted_reply_was_refunded_before_settlement' THEN RAISE; END IF;
    IF SQLERRM <> 'reply_already_persisted' THEN RAISE; END IF;
  END;
  IF public.settle_chat_turn(
    '10000000-0000-4000-8000-000000000005','40000000-0000-4000-8000-000000000005',
    '50000000-0000-4000-8000-000000000005') <> 'settled' THEN
    RAISE EXCEPTION 'late_reply_reconciliation_failed';
  END IF;
  BEGIN
    PERFORM * FROM public.refund_chat_turn(
      '10000000-0000-4000-8000-000000000005','40000000-0000-4000-8000-000000000005',
      '50000000-0000-4000-8000-000000000005','late_refund_attempt');
    RAISE EXCEPTION 'settled_turn_was_refunded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'settled_turn_was_refunded' THEN RAISE; END IF;
    IF SQLERRM <> 'settled_turn_cannot_be_refunded' THEN RAISE; END IF;
  END;
  SELECT count(*) INTO n FROM public.wallet_transactions
    WHERE user_id='10000000-0000-4000-8000-000000000005' AND biz_type='chat_turn_charge';
  IF n <> 1 THEN RAISE EXCEPTION 'late_reply_caused_duplicate_charge'; END IF;
END
$test$;


-- Stale unknown provider outcome: flag for manual review without refund or retry.
DO $test$
DECLARE r record; s integer; d integer; status_value text; attempts integer;
BEGIN
  INSERT INTO public.wallet_accounts(user_id,silver_coins,diamonds)
  VALUES ('10000000-0000-4000-8000-000000000006', 5, 1);
  INSERT INTO public.chat_sessions(id,user_id)
  VALUES ('20000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000006');
  INSERT INTO public.chat_messages(id,session_id,role,content)
  VALUES ('30000000-0000-4000-8000-000000000006','20000000-0000-4000-8000-000000000006','user','hello');
  PERFORM * FROM public.reserve_chat_turn(
    '10000000-0000-4000-8000-000000000006','40000000-0000-4000-8000-000000000006',
    '20000000-0000-4000-8000-000000000006','30000000-0000-4000-8000-000000000006',
    '50000000-0000-4000-8000-000000000006');
  UPDATE public.chat_turn_charges
  SET status='needs_reconciliation', failure_code='provider_request_outcome_unknown',
      updated_at=now()-interval '20 minutes'
  WHERE turn_id='40000000-0000-4000-8000-000000000006';

  SELECT * INTO r FROM public.reconcile_stale_story_chat_turns(10, 10, 30);
  IF r.processed <> 1 OR r.review_count <> 1 OR r.settled_count <> 0 OR r.failed_count <> 0 THEN
    RAISE EXCEPTION 'stale_unknown_outcome_not_flagged: %', row_to_json(r);
  END IF;
  SELECT status, reconciliation_attempts INTO status_value, attempts
  FROM public.chat_turn_charges WHERE turn_id='40000000-0000-4000-8000-000000000006';
  IF status_value <> 'needs_reconciliation' OR attempts <> 1 THEN
    RAISE EXCEPTION 'unknown_outcome_was_unlocked_or_not_counted';
  END IF;
  SELECT silver_coins, diamonds INTO s,d FROM public.wallet_accounts
  WHERE user_id='10000000-0000-4000-8000-000000000006';
  IF s <> 3 OR d <> 1 THEN
    RAISE EXCEPTION 'unknown_outcome_was_refunded_or_balance_changed: %, %',s,d;
  END IF;

  -- Review throttle: do not emit another review event on every scheduler tick.
  SELECT * INTO r FROM public.reconcile_stale_story_chat_turns(10, 10, 30);
  IF r.processed <> 0 THEN RAISE EXCEPTION 'review_throttle_failed: %',row_to_json(r); END IF;

  -- If a late durable reply subsequently appears, a later pass settles, never refunds.
  INSERT INTO public.chat_messages(id,session_id,role,content)
  VALUES ('50000000-0000-4000-8000-000000000006','20000000-0000-4000-8000-000000000006','assistant','late durable reply');
  UPDATE public.chat_turn_charges
  SET reconciliation_checked_at=now()-interval '31 minutes'
  WHERE turn_id='40000000-0000-4000-8000-000000000006';
  SELECT * INTO r FROM public.reconcile_stale_story_chat_turns(10, 10, 30);
  IF r.processed <> 1 OR r.settled_count <> 1 OR r.review_count <> 0 OR r.failed_count <> 0 THEN
    RAISE EXCEPTION 'late_durable_reply_not_settled: %',row_to_json(r);
  END IF;
  SELECT status INTO status_value FROM public.chat_turn_charges
  WHERE turn_id='40000000-0000-4000-8000-000000000006';
  IF status_value <> 'settled' THEN RAISE EXCEPTION 'late_reply_not_settled'; END IF;
END
$test$;

ROLLBACK;
