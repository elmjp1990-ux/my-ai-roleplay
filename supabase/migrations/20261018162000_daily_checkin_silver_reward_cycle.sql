-- PersonaX daily check-in: seven successful claims per cycle, 10 silver coins by default.
-- TEST project migration. Reward is controlled server-side in daily_checkin_settings.
create table if not exists public.daily_checkin_settings (
  id smallint primary key check (id = 1),
  reward_silver integer not null default 10 check (reward_silver > 0),
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into public.daily_checkin_settings (id, reward_silver, enabled)
values (1, 10, true)
on conflict (id) do nothing;

create table if not exists public.daily_checkins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  checkin_date date not null,
  cycle_day smallint not null check (cycle_day between 1 and 7),
  reward_silver integer not null check (reward_silver > 0),
  created_at timestamptz not null default now(),
  constraint daily_checkins_user_date_unique unique (user_id, checkin_date)
);
create index if not exists daily_checkins_user_date_idx
  on public.daily_checkins (user_id, checkin_date desc);

alter table public.daily_checkin_settings enable row level security;
alter table public.daily_checkins enable row level security;
revoke all on table public.daily_checkin_settings from anon, authenticated;
revoke all on table public.daily_checkins from anon, authenticated;

create or replace function public.get_daily_checkin_status()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_reward integer;
  v_enabled boolean;
  v_today_day smallint;
  v_last_day smallint;
  v_claimed_today boolean := false;
  v_next_day smallint := 1;
  v_last_date date;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if exists (select 1 from public.account_deletion_requests adr where adr.user_id = v_user_id) then
    raise exception 'account deletion pending' using errcode = '42501';
  end if;
  select s.reward_silver, s.enabled into v_reward, v_enabled
  from public.daily_checkin_settings s where s.id = 1;
  if not found then v_reward := 10; v_enabled := true; end if;
  select c.cycle_day into v_today_day from public.daily_checkins c
  where c.user_id = v_user_id and c.checkin_date = v_today;
  v_claimed_today := found;
  select c.cycle_day, c.checkin_date into v_last_day, v_last_date
  from public.daily_checkins c where c.user_id = v_user_id
  order by c.checkin_date desc limit 1;
  if v_claimed_today then v_next_day := v_today_day;
  elsif v_last_day is not null then v_next_day := (v_last_day % 7) + 1;
  end if;
  return jsonb_build_object('reward',v_reward,'enabled',v_enabled,'claimed_today',v_claimed_today,
    'cycle_day',v_next_day,'last_checkin_date',v_last_date,'today',v_today);
end;
$$;

create or replace function public.claim_daily_checkin()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_reward integer;
  v_enabled boolean;
  v_balance integer;
  v_last_day smallint;
  v_cycle_day smallint := 1;
  v_existing_day smallint;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if exists (select 1 from public.account_deletion_requests adr where adr.user_id = v_user_id) then
    raise exception 'account deletion pending' using errcode = '42501';
  end if;
  select wa.silver_coins into v_balance from public.wallet_accounts wa
  where wa.user_id = v_user_id for update;
  if not found then raise exception 'wallet account not found' using errcode = 'P0002'; end if;
  select s.reward_silver, s.enabled into v_reward, v_enabled
  from public.daily_checkin_settings s where s.id = 1;
  if not found then v_reward := 10; v_enabled := true; end if;
  if not v_enabled then raise exception 'daily check-in is disabled' using errcode = '42501'; end if;
  select c.cycle_day into v_existing_day from public.daily_checkins c
  where c.user_id = v_user_id and c.checkin_date = v_today;
  if found then
    return jsonb_build_object('granted',false,'claimed_today',true,'reward',v_reward,
      'cycle_day',v_existing_day,'silver_balance',v_balance,'today',v_today);
  end if;
  select c.cycle_day into v_last_day from public.daily_checkins c
  where c.user_id = v_user_id order by c.checkin_date desc limit 1;
  if v_last_day is not null then v_cycle_day := (v_last_day % 7) + 1; end if;
  insert into public.daily_checkins (user_id,checkin_date,cycle_day,reward_silver)
  values (v_user_id,v_today,v_cycle_day,v_reward);
  update public.wallet_accounts set silver_coins = silver_coins + v_reward, updated_at = now()
  where user_id = v_user_id returning silver_coins into v_balance;
  insert into public.wallet_transactions (user_id,currency_type,amount,biz_type,reference_id)
  values (v_user_id,'silver_coins',v_reward,'daily_checkin','daily_checkin:' || v_today::text);
  return jsonb_build_object('granted',true,'claimed_today',true,'reward',v_reward,
    'cycle_day',v_cycle_day,'silver_balance',v_balance,'today',v_today);
end;
$$;

revoke all on function public.get_daily_checkin_status() from public;
revoke all on function public.get_daily_checkin_status() from anon;
grant execute on function public.get_daily_checkin_status() to authenticated;
revoke all on function public.claim_daily_checkin() from public;
revoke all on function public.claim_daily_checkin() from anon;
grant execute on function public.claim_daily_checkin() to authenticated;

comment on table public.daily_checkin_settings is
  'Server-controlled daily check-in settings. Adjust reward_silver here; no client write access.';
comment on table public.daily_checkins is
  'Authoritative daily check-in history, one successful claim per user per Asia/Taipei calendar date.';
