-- TEST-only package purchase simulation.
-- No payment provider is called and no real charge is created.
-- The setting defaults to disabled; enable it manually only in the hosted TEST project.

alter table public.profiles
  add column if not exists membership_tier text not null default 'free',
  add column if not exists membership_expires_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and conname = 'profiles_membership_tier_check'
  ) then
    alter table public.profiles
      add constraint profiles_membership_tier_check
      check (membership_tier in ('free', 'monthly'));
  end if;
end
$$;

comment on column public.profiles.membership_tier is
  'Server-authoritative membership tier. Payment/subscription workflows must update this field; client metadata is not trusted.';
comment on column public.profiles.membership_expires_at is
  'Membership expiry timestamp. NULL means a monthly membership remains active until explicitly changed.';

create table if not exists public.diamond_test_purchase_settings (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

insert into public.diamond_test_purchase_settings(singleton, enabled)
values (true, false)
on conflict (singleton) do nothing;

alter table public.diamond_test_purchase_settings enable row level security;
revoke all on table public.diamond_test_purchase_settings from public, anon, authenticated;

create table if not exists public.diamond_test_purchase_requests (
  user_id uuid not null references public.profiles(id) on delete cascade,
  request_id uuid not null,
  package_code text not null,
  price_twd integer not null,
  base_diamonds integer not null,
  bonus_diamonds integer not null,
  created_at timestamptz not null default now(),
  primary key (user_id, request_id)
);

alter table public.diamond_test_purchase_requests enable row level security;
revoke all on table public.diamond_test_purchase_requests from public, anon, authenticated;

create unique index if not exists wallet_transactions_first_package_bonus_uidx
  on public.wallet_transactions(user_id, reference_id)
  where currency_type = 'diamonds'
    and biz_type = 'diamond_first_purchase_bonus';

create or replace function public.test_purchase_diamond_package(p_package_code text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_base_diamonds integer;
  v_price_twd integer;
  v_bonus_diamonds integer := 0;
  v_balance integer;
  v_test_enabled boolean;
  v_existing public.diamond_test_purchase_requests%rowtype;
begin
  if v_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if p_request_id is null then
    raise exception 'purchase request ID is required' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.account_deletion_requests adr
    where adr.user_id = v_user_id
  ) then
    raise exception 'account deletion pending' using errcode = '42501';
  end if;

  select s.enabled into v_test_enabled
  from public.diamond_test_purchase_settings s
  where s.singleton = true;

  if coalesce(v_test_enabled, false) is not true then
    raise exception 'TEST diamond package purchases are not enabled for this project' using errcode = '55000';
  end if;

  perform 1
  from public.profiles p
  where p.id = v_user_id;

  if not found then
    raise exception 'profile not found' using errcode = 'P0002';
  end if;

  case p_package_code
    when 'twd_60' then v_base_diamonds := 200; v_price_twd := 60;
    when 'twd_150' then v_base_diamonds := 525; v_price_twd := 150;
    when 'twd_290' then v_base_diamonds := 1050; v_price_twd := 290;
    when 'twd_850' then v_base_diamonds := 3200; v_price_twd := 850;
    when 'twd_1390' then v_base_diamonds := 5400; v_price_twd := 1390;
    when 'twd_2690' then v_base_diamonds := 11000; v_price_twd := 2690;
    else
      raise exception 'invalid diamond package code' using errcode = '22023';
  end case;

  select wa.diamonds into v_balance
  from public.wallet_accounts wa
  where wa.user_id = v_user_id
  for update;

  if not found then
    raise exception 'wallet account not found' using errcode = 'P0002';
  end if;

  -- A retried client request returns its original result without crediting twice.
  select r.* into v_existing
  from public.diamond_test_purchase_requests r
  where r.user_id = v_user_id
    and r.request_id = p_request_id;

  if found then
    return jsonb_build_object(
      'status', 'granted',
      'test_only', true,
      'replayed', true,
      'package_code', v_existing.package_code,
      'price_twd', v_existing.price_twd,
      'base_diamonds', v_existing.base_diamonds,
      'bonus_diamonds', v_existing.bonus_diamonds,
      'diamonds', v_balance
    );
  end if;

  -- Membership is independent of diamond package promotions.
  -- Every account may claim the 30% first-purchase bonus once per package tier.
  if not exists (
    select 1
    from public.wallet_transactions wt
    where wt.user_id = v_user_id
      and wt.currency_type = 'diamonds'
      and wt.biz_type = 'diamond_first_purchase_bonus'
      and wt.reference_id = p_package_code
  ) then
    v_bonus_diamonds := round(v_base_diamonds * 0.30)::integer;
  end if;

  insert into public.diamond_test_purchase_requests
    (user_id, request_id, package_code, price_twd, base_diamonds, bonus_diamonds)
  values
    (v_user_id, p_request_id, p_package_code, v_price_twd, v_base_diamonds, v_bonus_diamonds);

  update public.wallet_accounts
  set diamonds = diamonds + v_base_diamonds + v_bonus_diamonds,
      updated_at = now()
  where user_id = v_user_id
  returning diamonds into v_balance;

  -- Purchased package and promotional bonus are deliberately separate ledger rows.
  insert into public.wallet_transactions
    (user_id, currency_type, amount, biz_type, reference_id)
  values
    (v_user_id, 'diamonds', v_base_diamonds, 'test_diamond_purchase', p_request_id::text);

  if v_bonus_diamonds > 0 then
    insert into public.wallet_transactions
      (user_id, currency_type, amount, biz_type, reference_id)
    values
      (v_user_id, 'diamonds', v_bonus_diamonds, 'diamond_first_purchase_bonus', p_package_code);
  end if;

  return jsonb_build_object(
    'status', 'granted',
    'test_only', true,
    'package_code', p_package_code,
    'price_twd', v_price_twd,
    'base_diamonds', v_base_diamonds,
    'bonus_diamonds', v_bonus_diamonds,
    'diamonds', v_balance
  );
end;
$function$;

revoke all on function public.test_purchase_diamond_package(text, uuid) from public, anon;
grant execute on function public.test_purchase_diamond_package(text, uuid) to authenticated;

comment on function public.test_purchase_diamond_package(text, uuid) is
  'TEST-only simulated diamond package grant. Requires explicit project-local enablement; creates no payment or provider transaction.';
