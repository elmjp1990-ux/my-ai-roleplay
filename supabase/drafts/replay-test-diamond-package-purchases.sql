-- Disposable local regression test for the TEST diamond package purchase RPC.
-- Runs inside a transaction and rolls back all synthetic rows and setting changes.

begin;

do $diamond_package_test$
declare
  v_free_uid uuid := 'a1111111-1111-4111-8111-111111111111';
  v_member_uid uuid := 'b2222222-2222-4222-8222-222222222222';
  v_result jsonb;
  v_free_balance integer;
  v_member_balance integer;
  v_free_base_rows integer;
  v_free_bonus_rows integer;
  v_member_bonus_rows integer;
begin
  -- Use synthetic profile IDs without requiring Auth fixtures. This is a
  -- disposable local database only; all rows are rolled back below.
  set local session_replication_role = replica;
  insert into public.profiles
    (id, handle, nickname, persona_presets, follower_count, membership_tier, membership_expires_at)
  values
    (v_free_uid, 'diamond_test_free_user', 'Diamond Free Test', '[]'::jsonb, 0, 'free', null),
    (v_member_uid, 'diamond_test_monthly_user', 'Diamond Monthly Test', '[]'::jsonb, 0, 'monthly', now() + interval '30 days');
  insert into public.wallet_accounts(user_id, diamonds, silver_coins)
  values (v_free_uid, 0, 100), (v_member_uid, 0, 100);
  set local session_replication_role = origin;

  perform set_config('request.jwt.claim.sub', v_free_uid::text, true);

  -- The RPC must refuse grants until an operator enables the TEST-only switch.
  begin
    perform public.test_purchase_diamond_package('twd_60', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    raise exception 'TEST package purchase should be blocked while the feature flag is disabled';
  exception when sqlstate '55000' then
    null;
  end;

  update public.diamond_test_purchase_settings
  set enabled = true
  where singleton = true;

  -- First purchase of the NT$60 tier: 200 base + 60 bonus.
  v_result := public.test_purchase_diamond_package('twd_60', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  if (v_result->>'base_diamonds')::integer <> 200
     or (v_result->>'bonus_diamonds')::integer <> 60
     or (v_result->>'diamonds')::integer <> 260 then
    raise exception 'First NT$60 package grant mismatch: %', v_result;
  end if;

  -- Retrying the same request ID must not credit either row twice.
  v_result := public.test_purchase_diamond_package('twd_60', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  if (v_result->>'base_diamonds')::integer <> 200
     or (v_result->>'bonus_diamonds')::integer <> 60
     or (v_result->>'diamonds')::integer <> 260
     or (v_result->>'replayed')::boolean is not true then
    raise exception 'Repeated request ID must return the original result without a second grant: %', v_result;
  end if;

  -- A new purchase request for the same tier grants the base package only.
  v_result := public.test_purchase_diamond_package('twd_60', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
  if (v_result->>'base_diamonds')::integer <> 200
     or (v_result->>'bonus_diamonds')::integer <> 0
     or (v_result->>'diamonds')::integer <> 460 then
    raise exception 'Repeated NT$60 tier must not repeat the bonus: %', v_result;
  end if;

  -- Every other tier has an independent first-purchase bonus.
  v_result := public.test_purchase_diamond_package('twd_150', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd');
  if (v_result->>'base_diamonds')::integer <> 525
     or (v_result->>'bonus_diamonds')::integer <> 158
     or (v_result->>'diamonds')::integer <> 1143 then
    raise exception 'First NT$150 package grant mismatch: %', v_result;
  end if;

  v_result := public.test_purchase_diamond_package('twd_290', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee');
  if (v_result->>'base_diamonds')::integer <> 1050
     or (v_result->>'bonus_diamonds')::integer <> 315
     or (v_result->>'diamonds')::integer <> 2508 then
    raise exception 'First NT$290 package grant mismatch: %', v_result;
  end if;

  v_result := public.test_purchase_diamond_package('twd_850', 'ffffffff-ffff-4fff-8fff-ffffffffffff');
  if (v_result->>'base_diamonds')::integer <> 3200
     or (v_result->>'bonus_diamonds')::integer <> 960
     or (v_result->>'diamonds')::integer <> 6668 then
    raise exception 'First NT$850 package grant mismatch: %', v_result;
  end if;

  v_result := public.test_purchase_diamond_package('twd_1390', '11111111-2222-4333-8444-555555555555');
  if (v_result->>'base_diamonds')::integer <> 5400
     or (v_result->>'bonus_diamonds')::integer <> 1620
     or (v_result->>'diamonds')::integer <> 13688 then
    raise exception 'First NT$1,390 package grant mismatch: %', v_result;
  end if;

  v_result := public.test_purchase_diamond_package('twd_2690', '22222222-3333-4444-8555-666666666666');
  if (v_result->>'base_diamonds')::integer <> 11000
     or (v_result->>'bonus_diamonds')::integer <> 3300
     or (v_result->>'diamonds')::integer <> 27988 then
    raise exception 'First NT$2,690 package grant mismatch: %', v_result;
  end if;

  select count(*) into v_free_base_rows
  from public.wallet_transactions
  where user_id = v_free_uid
    and biz_type = 'test_diamond_purchase'
    and currency_type = 'diamonds';

  select count(*) into v_free_bonus_rows
  from public.wallet_transactions
  where user_id = v_free_uid
    and biz_type = 'diamond_first_purchase_bonus'
    and currency_type = 'diamonds';

  if v_free_base_rows <> 7 or v_free_bonus_rows <> 6 then
    raise exception 'Free-user ledger separation mismatch: base %, bonus %',
      v_free_base_rows, v_free_bonus_rows;
  end if;

  select diamonds into v_free_balance
  from public.wallet_accounts
  where user_id = v_free_uid;

  if v_free_balance <> 27988 then
    raise exception 'Final free-user wallet balance mismatch: %', v_free_balance;
  end if;

  -- Active monthly membership suppresses the bonus, but not the base package.
  perform set_config('request.jwt.claim.sub', v_member_uid::text, true);
  v_result := public.test_purchase_diamond_package('twd_60', '33333333-4444-4555-8666-777777777777');
  if (v_result->>'base_diamonds')::integer <> 200
     or (v_result->>'bonus_diamonds')::integer <> 0
     or (v_result->>'diamonds')::integer <> 200 then
    raise exception 'Monthly member must not receive first-purchase bonus: %', v_result;
  end if;

  select count(*) into v_member_bonus_rows
  from public.wallet_transactions
  where user_id = v_member_uid
    and biz_type = 'diamond_first_purchase_bonus'
    and currency_type = 'diamonds';

  select diamonds into v_member_balance
  from public.wallet_accounts
  where user_id = v_member_uid;

  if v_member_bonus_rows <> 0 or v_member_balance <> 200 then
    raise exception 'Monthly member bonus or balance mismatch: bonus rows %, balance %',
      v_member_bonus_rows, v_member_balance;
  end if;

  -- Invalid package codes must be rejected.
  begin
    perform public.test_purchase_diamond_package('twd_999', '44444444-5555-4666-8777-888888888888');
    raise exception 'Invalid package code should have been rejected';
  exception when sqlstate '22023' then
    null;
  end;
end;
$diamond_package_test$;

rollback;
