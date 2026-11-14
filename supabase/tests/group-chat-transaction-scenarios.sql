-- Executes against the disposable PostgreSQL service used by GitHub Actions.
\set ON_ERROR_STOP on

INSERT INTO auth.users(id) VALUES
 ('10000000-0000-4000-8000-000000000001'),
 ('10000000-0000-4000-8000-000000000002'),
 ('10000000-0000-4000-8000-000000000003'),
 ('10000000-0000-4000-8000-000000000004'),
 ('10000000-0000-4000-8000-000000000005'),
 ('10000000-0000-4000-8000-000000000006'),
 ('10000000-0000-4000-8000-000000000007');

INSERT INTO public.wallet_accounts(user_id,silver_coins,diamonds) VALUES
 ('10000000-0000-4000-8000-000000000001',4,5),
 ('10000000-0000-4000-8000-000000000002',10,0),
 ('10000000-0000-4000-8000-000000000003',10,0),
 ('10000000-0000-4000-8000-000000000004',2,0),
 ('10000000-0000-4000-8000-000000000005',5,0),
 ('10000000-0000-4000-8000-000000000006',10,0),
 ('10000000-0000-4000-8000-000000000007',10,0);

INSERT INTO public.chat_groups(id,owner_id,name) VALUES
 ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','complete'),
 ('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','timeout'),
 ('20000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000003','deleted'),
 ('20000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000004','insufficient'),
 ('20000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000005','race-a'),
 ('20000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000005','race-b'),
 ('20000000-0000-4000-8000-000000000007','10000000-0000-4000-8000-000000000006','idempotent'),
 ('20000000-0000-4000-8000-000000000008','10000000-0000-4000-8000-000000000007','completion-race');

INSERT INTO public.chat_group_members(group_id,character_id,position,character_snapshot) VALUES
 ('20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001',1,'{"id":"30000000-0000-4000-8000-000000000001","name":"A"}'),
 ('20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002',2,'{"id":"30000000-0000-4000-8000-000000000002","name":"B"}'),
 ('20000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000003',1,'{"id":"30000000-0000-4000-8000-000000000003","name":"C"}'),
 ('20000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000004',1,'{"id":"30000000-0000-4000-8000-000000000004","name":"D"}'),
 ('20000000-0000-4000-8000-000000000004','30000000-0000-4000-8000-000000000005',1,'{"id":"30000000-0000-4000-8000-000000000005","name":"E"}'),
 ('20000000-0000-4000-8000-000000000005','30000000-0000-4000-8000-000000000006',1,'{"id":"30000000-0000-4000-8000-000000000006","name":"F"}'),
 ('20000000-0000-4000-8000-000000000006','30000000-0000-4000-8000-000000000007',1,'{"id":"30000000-0000-4000-8000-000000000007","name":"G"}'),
 ('20000000-0000-4000-8000-000000000007','30000000-0000-4000-8000-000000000008',1,'{"id":"30000000-0000-4000-8000-000000000008","name":"H"}'),
 ('20000000-0000-4000-8000-000000000008','30000000-0000-4000-8000-000000000009',1,'{"id":"30000000-0000-4000-8000-000000000009","name":"I"}');

SET ROLE service_role;
DO $$
DECLARE r record; v_turn uuid; v_count integer; v_balance public.wallet_accounts%rowtype;
BEGIN
  -- 2 members cost 6; consume 4 silver first and 2 diamonds second.
  SELECT * INTO r FROM public.reserve_group_chat_turn(
    '10000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    '40000000-0000-4000-8000-000000000001',
    'complete this turn'
  );
  IF r.cost <> 6 OR r.silver_charged <> 4 OR r.diamonds_charged <> 2 THEN
    RAISE EXCEPTION 'silver-first reservation mismatch: %', row_to_json(r);
  END IF;
  v_turn := r.turn_id;
  SELECT * INTO r FROM public.reserve_group_chat_turn(
    '10000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    '40000000-0000-4000-8000-000000000001',
    'complete this turn'
  );
  IF r.turn_id <> v_turn OR r.is_new OR r.cost <> 6 THEN
    RAISE EXCEPTION 'idempotent replay created a new turn';
  END IF;
  SELECT count(*) INTO v_count FROM public.wallet_transactions
  WHERE reference_id = v_turn::text AND biz_type = 'group_chat_turn_charge';
  IF v_count <> 2 THEN RAISE EXCEPTION 'duplicate charge ledger rows: %', v_count; END IF;

  IF public.complete_group_chat_turn(
    '10000000-0000-4000-8000-000000000001', v_turn,
    '[{"speaker_id":"30000000-0000-4000-8000-000000000001","content":"completed reply"}]'::jsonb
  ) <> 'completed' THEN RAISE EXCEPTION 'completion did not settle'; END IF;
  BEGIN
    PERFORM * FROM public.refund_group_chat_turn(
      '10000000-0000-4000-8000-000000000001',v_turn,'should_not_refund'
    );
    RAISE EXCEPTION 'settled turn was incorrectly refunded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'completed_group_turn_cannot_be_refunded%' THEN RAISE; END IF;
  END;

  -- Expired processing turn: watchdog restores the exact reserved currencies.
  SELECT * INTO r FROM public.reserve_group_chat_turn(
    '10000000-0000-4000-8000-000000000002',
    '20000000-0000-4000-8000-000000000002',
    '40000000-0000-4000-8000-000000000002',
    'timeout this turn'
  );
  v_turn := r.turn_id;
  UPDATE public.chat_group_turns
  SET processing_started_at = clock_timestamp() - interval '60 seconds'
  WHERE id = v_turn;
  IF public.run_group_chat_turn_watchdog(100) <> 1 THEN
    RAISE EXCEPTION 'watchdog did not refund the overdue turn';
  END IF;
  SELECT * INTO v_balance FROM public.wallet_accounts
  WHERE user_id = '10000000-0000-4000-8000-000000000002';
  IF v_balance.silver_coins <> 10 OR v_balance.diamonds <> 0 THEN
    RAISE EXCEPTION 'watchdog did not restore exact wallet balances';
  END IF;
  IF (SELECT status FROM public.chat_group_turn_charges WHERE group_turn_id = v_turn) <> 'refunded'
    OR (SELECT status FROM public.chat_group_turns WHERE id = v_turn) <> 'failed' THEN
    RAISE EXCEPTION 'watchdog did not persist terminal refund states';
  END IF;
  IF EXISTS (SELECT 1 FROM public.chat_group_messages WHERE turn_id = v_turn) THEN
    RAISE EXCEPTION 'refunded turn retained player/AI messages';
  END IF;
  PERFORM * FROM public.expire_group_chat_turn(
    '10000000-0000-4000-8000-000000000002',v_turn
  );
  SELECT count(*) INTO v_count FROM public.wallet_transactions
  WHERE reference_id = v_turn::text AND biz_type = 'group_chat_turn_refund';
  IF v_count <> 1 THEN RAISE EXCEPTION 'refund was not idempotent: %', v_count; END IF;

  -- A soft-deleted group must still allow a previously reserved refund.
  SELECT * INTO r FROM public.reserve_group_chat_turn(
    '10000000-0000-4000-8000-000000000003',
    '20000000-0000-4000-8000-000000000003',
    '40000000-0000-4000-8000-000000000003',
    'deleted during generation'
  );
  v_turn := r.turn_id;
  UPDATE public.chat_groups SET deleted_at = now()
  WHERE id = '20000000-0000-4000-8000-000000000003';
  UPDATE public.chat_group_turns SET processing_started_at = clock_timestamp() - interval '60 seconds'
  WHERE id = v_turn;
  SELECT * INTO r FROM public.expire_group_chat_turn(
    '10000000-0000-4000-8000-000000000003',v_turn
  );
  IF r.status <> 'refunded' THEN RAISE EXCEPTION 'soft-deleted group turn did not refund'; END IF;

  -- Insufficient funds must leave wallet and ledger untouched.
  BEGIN
    PERFORM * FROM public.reserve_group_chat_turn(
      '10000000-0000-4000-8000-000000000004',
      '20000000-0000-4000-8000-000000000004',
      '40000000-0000-4000-8000-000000000004',
      'cannot afford this turn'
    );
    RAISE EXCEPTION 'insufficient balance was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'group_insufficient_funds:%' THEN RAISE; END IF;
  END;
  SELECT * INTO v_balance FROM public.wallet_accounts
  WHERE user_id = '10000000-0000-4000-8000-000000000004';
  IF v_balance.silver_coins <> 2 OR v_balance.diamonds <> 0 THEN
    RAISE EXCEPTION 'insufficient-funds attempt partially charged wallet';
  END IF;
  IF EXISTS (SELECT 1 FROM public.chat_group_turns WHERE group_id = '20000000-0000-4000-8000-000000000004') THEN
    RAISE EXCEPTION 'insufficient-funds attempt created a turn';
  END IF;
END
$$;
RESET ROLE;

-- Scheduler must be installed exactly once by the migration.
DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM cron.job
  WHERE jobname = 'poyozz-group-chat-turn-watchdog';
  IF n <> 1 THEN RAISE EXCEPTION 'expected exactly one watchdog cron job, found %', n; END IF;
END
$$;
