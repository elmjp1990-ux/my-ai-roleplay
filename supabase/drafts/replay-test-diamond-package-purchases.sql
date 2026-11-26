-- Disposable local regression test for the TEST diamond package purchase RPC.
-- Runs inside a transaction and rolls back all synthetic rows and setting changes.

begin;

do $diamond_package_test$
declare
  v_uid uuid := 'a1111111-1111-4111-8111-111111111111';
  v_result jsonb;
  v_balance integer;
  v_base_rows integer;
  v_bonus_rows integer;
  v_bonus_for_first_tier integer;
begin
  -- Use a synthetic profile ID without requiring an Auth fixture. This is a
  -- disposable local database only; all rows are rolled back below.
  set local session_replication_role = replica;
  insert into public.profiles
    (id, handle, nickname, persona_presets, follower_count)
  values
    (v_uid, 'diamond_test_user', 'Diamond Test', '[]'::jsonb, 0);
  insert into public.wallet_accounts(user_id, diamonds, silver_coins)
  values (v_uid, 0, 100);
  set local session_replication_role = origin;

  perform set_config('request.jwt.claim.sub', v_uid::text, true);

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
  v_result := public.test_purchase_diamond_package('twd_60');
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

  -- A different tier has its own first-purchase entitlement; 30% of 525 rounds to 158.
  v_result := public.test_purchase_diamond_package('twd_150', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd');
  if (v_result->>'base_diamonds')::integer <> 525
     or (v_result->>'bonus_diamonds')::integer <> 158
     or (v_result->>'diamonds')::integer <> 1143 then
    raise exception 'First NT$150 package grant mismatch: %', v_result;
  end if;

  -- Active monthly membership suppresses the bonus, but not the base test package.
  update public.profiles
  set membership_tier = 'monthly',
      membership_expires_at = now() + interval '30 days'
  where id = v_uid;

  v_result := public.test_purchase_diamond_package('twd_290', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee');
  if (v_result->>'base_diamonds')::integer <> 1050
     or (v_result->>'bonus_diamonds')::integer <> 0
     or (v_result->>'diamonds')::integer <> 2193 then
    raise exception 'Monthly member must not receive first-purchase bonus: %', v_result;
  end if;

  select count(*) into v_base_rows
  from public.wallet_transactions
  where user_id = v_uid
    and biz_type = 'test_diamond_purchase'
    and currency_type = 'diamonds';

  select count(*) into v_bonus_rows
  from public.wallet_transactions
  where user_id = v_uid
    and biz_type = 'diamond_first_purchase_bonus'
    and currency_type = 'diamonds';

  select count(*) into v_bonus_for_first_tier
  from public.wallet_transactions
  where user_id = v_uid
    and biz_type = 'diamond_first_purchase_bonus'
    and reference_id = 'twd_60';

  if v_base_rows <> 4 or v_bonus_rows <> 2 or v_bonus_for_first_tier <> 1 then
    raise exception 'Ledger separation / per-tier one-time bonus mismatch: base %, bonus %, tier60 %',
      v_base_rows, v_bonus_rows, v_bonus_for_first_tier;
  end if;

  select diamonds into v_balance
  from public.wallet_accounts
  where user_id = v_uid;

  if v_balance <> 2193 then
    raise exception 'Final wallet balance mismatch: %', v_balance;
  end if;

  -- Invalid package codes must be rejected.
  begin
    perform public.test_purchase_diamond_package('twd_999', 'ffffffff-ffff-4fff-8fff-ffffffffffff');
    raise exception 'Invalid package code should have been rejected';
  exception when sqlstate '22023' then
    null;
  end;
end;
$diamond_package_test$;

rollback;
