-- TEST ONLY: one-time 200-diamond grant for UI acceptance.
-- Remove this function and its frontend button before public launch.
create or replace function public.test_grant_diamonds_200()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_balance integer;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.account_deletion_requests adr
    where adr.user_id = v_user_id
  ) then
    raise exception 'account deletion pending' using errcode = '42501';
  end if;

  select wa.diamonds
    into v_balance
  from public.wallet_accounts wa
  where wa.user_id = v_user_id
  for update;

  if not found then
    raise exception 'wallet account not found' using errcode = 'P0002';
  end if;

  if exists (
    select 1
    from public.wallet_transactions wt
    where wt.user_id = v_user_id
      and wt.currency_type = 'diamonds'
      and wt.biz_type = 'test_purchase_200'
      and wt.reference_id = 'test_purchase_200_once'
  ) then
    return jsonb_build_object('diamonds', v_balance, 'granted', false);
  end if;

  update public.wallet_accounts
    set diamonds = diamonds + 200,
        updated_at = now()
  where user_id = v_user_id
  returning diamonds into v_balance;

  insert into public.wallet_transactions
    (user_id, currency_type, amount, biz_type, reference_id)
  values
    (v_user_id, 'diamonds', 200, 'test_purchase_200', 'test_purchase_200_once');

  return jsonb_build_object('diamonds', v_balance, 'granted', true);
end;
$$;

revoke all on function public.test_grant_diamonds_200() from public;
revoke all on function public.test_grant_diamonds_200() from anon;
grant execute on function public.test_grant_diamonds_200() to authenticated;

comment on function public.test_grant_diamonds_200() is
  'TEST ONLY: grants exactly 200 diamonds once per account for UI testing; remove before public launch.';
