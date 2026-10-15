-- PersonaX chat-turn wallet charging SQL reference source.
-- The equivalent SQL was applied to production as migration wallet_chat_turn_charging on 2026-10-15.
-- This file remains outside supabase/migrations; edits here do not change production.
-- Server orchestration must call these RPCs with the service-role client only.
-- Never expose reserve/settle/refund to browser-authenticated users.

begin;

create table if not exists public.chat_turn_charges (
  turn_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  user_message_id uuid not null references public.chat_messages(id) on delete restrict,
  expected_assistant_message_id uuid not null unique,
  assistant_message_id uuid references public.chat_messages(id) on delete set null,
  cost integer not null default 2 check (cost = 2),
  silver_reserved integer not null default 0 check (silver_reserved >= 0),
  diamonds_reserved integer not null default 0 check (diamonds_reserved >= 0),
  status text not null default 'created'
    check (status in ('created','reserved','settled','refunded','needs_reconciliation','insufficient_funds')),
  failure_code text,
  created_at timestamptz not null default now(),
  reserved_at timestamptz,
  settled_at timestamptz,
  refunded_at timestamptz,
  updated_at timestamptz not null default now(),
  check (silver_reserved + diamonds_reserved in (0, 2))
);

create table if not exists public.chat_turn_events (
  event_id bigint generated always as identity primary key,
  turn_id uuid not null references public.chat_turn_charges(turn_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  event_type text not null,
  stage text not null,
  error_code text,
  retryable boolean not null default false,
  attempt integer not null default 1 check (attempt > 0),
  duration_ms integer check (duration_ms is null or duration_ms >= 0),
  created_at timestamptz not null default now()
);

create index if not exists chat_turn_charges_user_created_idx
  on public.chat_turn_charges(user_id, created_at desc);
create index if not exists chat_turn_charges_status_updated_idx
  on public.chat_turn_charges(status, updated_at);
create index if not exists chat_turn_events_turn_created_idx
  on public.chat_turn_events(turn_id, created_at);
create unique index if not exists wallet_transactions_chat_turn_idempotency_uidx
  on public.wallet_transactions(user_id, biz_type, reference_id, currency_type)
  where reference_id is not null and biz_type in ('chat_turn_charge','chat_turn_refund');

alter table public.chat_turn_charges enable row level security;
alter table public.chat_turn_events enable row level security;
revoke all on public.chat_turn_charges from anon, authenticated;
revoke all on public.chat_turn_events from anon, authenticated;
grant select, insert, update, delete on public.chat_turn_charges to service_role;
grant select, insert on public.chat_turn_events to service_role;
grant usage, select on sequence public.chat_turn_events_event_id_seq to service_role;

create or replace function public.reserve_chat_turn(
  p_user_id uuid,
  p_turn_id uuid,
  p_session_id uuid,
  p_user_message_id uuid,
  p_assistant_message_id uuid
)
returns table(turn_id uuid, status text, silver_reserved integer, diamonds_reserved integer, balance_silver integer, balance_diamonds integer)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_charge public.chat_turn_charges%rowtype;
  v_wallet public.wallet_accounts%rowtype;
  v_silver integer;
  v_diamonds integer;
begin
  if p_user_id is null or p_turn_id is null or p_session_id is null or p_user_message_id is null or p_assistant_message_id is null then
    raise exception 'invalid_turn_request';
  end if;

  if exists (select 1 from public.account_deletion_requests r where r.user_id = p_user_id) then
    raise exception 'account_not_active';
  end if;

  if not exists (
    select 1 from public.chat_sessions s
    where s.id = p_session_id and s.user_id = p_user_id and s.deleted_at is null
  ) then raise exception 'chat_session_not_owned_or_active'; end if;

  if not exists (
    select 1 from public.chat_messages m
    where m.id = p_user_message_id and m.session_id = p_session_id
      and m.role = 'user' and m.deleted_at is null
  ) then raise exception 'user_message_not_found'; end if;

  insert into public.chat_turn_charges(turn_id,user_id,session_id,user_message_id,expected_assistant_message_id,cost,status)
  values (p_turn_id,p_user_id,p_session_id,p_user_message_id,p_assistant_message_id,2,'created')
  on conflict (turn_id) do nothing;

  select c.* into v_charge
  from public.chat_turn_charges c
  where c.turn_id = p_turn_id
  for update;

  if v_charge.user_id <> p_user_id
     or v_charge.session_id <> p_session_id
     or v_charge.user_message_id <> p_user_message_id
     or v_charge.expected_assistant_message_id <> p_assistant_message_id then
    raise exception 'turn_id_reuse_conflict';
  end if;

  if v_charge.status <> 'created' then
    select w.silver_coins, w.diamonds into v_silver, v_diamonds
    from public.wallet_accounts w where w.user_id = p_user_id;
    return query select v_charge.turn_id, v_charge.status,
      v_charge.silver_reserved, v_charge.diamonds_reserved, v_silver, v_diamonds;
    return;
  end if;

  select w.* into v_wallet
  from public.wallet_accounts w where w.user_id = p_user_id for update;

  if not found then raise exception 'wallet_not_initialized'; end if;

  if v_wallet.silver_coins + v_wallet.diamonds < 2 then
    update public.chat_turn_charges c set status='insufficient_funds', updated_at=now()
      where c.turn_id=p_turn_id;
    insert into public.chat_turn_events(turn_id,user_id,event_type,stage,error_code)
      values (p_turn_id,p_user_id,'insufficient_balance','reservation','insufficient_funds');
    return query select p_turn_id, 'insufficient_funds'::text, 0, 0,
      v_wallet.silver_coins, v_wallet.diamonds;
    return;
  end if;

  v_silver := least(v_wallet.silver_coins, 2);
  v_diamonds := 2 - v_silver;

  update public.wallet_accounts w
  set silver_coins = w.silver_coins - v_silver,
      diamonds = w.diamonds - v_diamonds,
      updated_at = now()
  where w.user_id = p_user_id;

  if v_silver > 0 then
    insert into public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id)
    values (p_user_id,'silver_coins',-v_silver,'chat_turn_charge',p_turn_id::text);
  end if;
  if v_diamonds > 0 then
    insert into public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id)
    values (p_user_id,'diamonds',-v_diamonds,'chat_turn_charge',p_turn_id::text);
  end if;

  update public.chat_turn_charges c
  set status='reserved', silver_reserved=v_silver, diamonds_reserved=v_diamonds,
      reserved_at=now(), updated_at=now()
  where c.turn_id=p_turn_id;

  insert into public.chat_turn_events(turn_id,user_id,event_type,stage)
    values (p_turn_id,p_user_id,'reserved','reservation');

  select w.silver_coins, w.diamonds into v_silver, v_diamonds
  from public.wallet_accounts w where w.user_id=p_user_id;
  return query select p_turn_id, 'reserved'::text,
    (select c.silver_reserved from public.chat_turn_charges c where c.turn_id=p_turn_id),
    (select c.diamonds_reserved from public.chat_turn_charges c where c.turn_id=p_turn_id),
    v_silver, v_diamonds;
end;
$function$;

create or replace function public.settle_chat_turn(
  p_user_id uuid,
  p_turn_id uuid,
  p_assistant_message_id uuid
)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_charge public.chat_turn_charges%rowtype;
begin
  select c.* into v_charge from public.chat_turn_charges c
  where c.turn_id=p_turn_id for update;
  if not found or v_charge.user_id <> p_user_id then raise exception 'turn_not_found'; end if;
  if v_charge.expected_assistant_message_id is distinct from p_assistant_message_id then
    raise exception 'turn_assistant_id_conflict';
  end if;
  if v_charge.status = 'settled' then
    if v_charge.assistant_message_id is distinct from p_assistant_message_id then
      raise exception 'settled_turn_reply_id_conflict';
    end if;
    return 'settled';
  end if;
  if v_charge.status not in ('reserved','needs_reconciliation') then
    raise exception 'turn_not_settleable';
  end if;
  if not exists (
    select 1 from public.chat_messages m
    where m.id=p_assistant_message_id and m.session_id=v_charge.session_id
      and m.role='assistant' and m.deleted_at is null and length(btrim(m.content)) > 0
  ) then raise exception 'durable_assistant_reply_not_found'; end if;

  update public.chat_turn_charges c
  set status='settled', assistant_message_id=p_assistant_message_id,
      settled_at=now(), updated_at=now()
  where c.turn_id=p_turn_id;
  insert into public.chat_turn_events(turn_id,user_id,event_type,stage)
    values (p_turn_id,p_user_id,'settled','persistence');
  return 'settled';
end;
$function$;

create or replace function public.refund_chat_turn(
  p_user_id uuid,
  p_turn_id uuid,
  p_assistant_message_id uuid,
  p_failure_code text
)
returns table(status text, balance_silver integer, balance_diamonds integer)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_charge public.chat_turn_charges%rowtype;
  v_wallet public.wallet_accounts%rowtype;
begin
  select c.* into v_charge from public.chat_turn_charges c
  where c.turn_id=p_turn_id for update;
  if not found or v_charge.user_id <> p_user_id then raise exception 'turn_not_found'; end if;
  if v_charge.expected_assistant_message_id is distinct from p_assistant_message_id then
    raise exception 'turn_assistant_id_conflict';
  end if;
  if v_charge.status = 'refunded' then
    select w.silver_coins,w.diamonds into v_wallet.silver_coins,v_wallet.diamonds
      from public.wallet_accounts w where w.user_id=p_user_id;
    return query select 'refunded'::text,v_wallet.silver_coins,v_wallet.diamonds;
    return;
  end if;
  if v_charge.status = 'settled' then raise exception 'settled_turn_cannot_be_refunded'; end if;
  if v_charge.status not in ('reserved','needs_reconciliation') then raise exception 'turn_not_refundable'; end if;
  if p_assistant_message_id is not null and exists (
    select 1 from public.chat_messages m
    where m.id=p_assistant_message_id and m.session_id=v_charge.session_id
      and m.role='assistant' and m.deleted_at is null and length(btrim(m.content)) > 0
  ) then raise exception 'reply_already_persisted'; end if;

  select w.* into v_wallet from public.wallet_accounts w
    where w.user_id=p_user_id for update;
  if not found then raise exception 'wallet_not_initialized'; end if;

  update public.wallet_accounts w
  set silver_coins=w.silver_coins+v_charge.silver_reserved,
      diamonds=w.diamonds+v_charge.diamonds_reserved,
      updated_at=now()
  where w.user_id=p_user_id;

  if v_charge.silver_reserved > 0 then
    insert into public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id)
    values (p_user_id,'silver_coins',v_charge.silver_reserved,'chat_turn_refund',p_turn_id::text);
  end if;
  if v_charge.diamonds_reserved > 0 then
    insert into public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id)
    values (p_user_id,'diamonds',v_charge.diamonds_reserved,'chat_turn_refund',p_turn_id::text);
  end if;

  update public.chat_turn_charges c
  set status='refunded', failure_code=left(coalesce(p_failure_code,'confirmed_failure'),80),
      refunded_at=now(), updated_at=now()
  where c.turn_id=p_turn_id;
  insert into public.chat_turn_events(turn_id,user_id,event_type,stage,error_code)
    values (p_turn_id,p_user_id,'refunded','recovery',left(coalesce(p_failure_code,'confirmed_failure'),80));

  select w.silver_coins,w.diamonds into v_wallet.silver_coins,v_wallet.diamonds
    from public.wallet_accounts w where w.user_id=p_user_id;
  return query select 'refunded'::text,v_wallet.silver_coins,v_wallet.diamonds;
end;
$function$;

-- Serialize assistant-message persistence against refunds. This closes the race where
-- a refund checks for no reply while a concurrent request is still inserting it.
create or replace function public.guard_chat_turn_assistant_insert()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_charge public.chat_turn_charges%rowtype;
begin
  if new.role <> 'assistant' then
    return new;
  end if;

  select c.* into v_charge
  from public.chat_turn_charges c
  where c.expected_assistant_message_id = new.id
  for update;

  if found then
    if length(btrim(coalesce(new.content, ''))) = 0 then
      raise exception 'assistant_reply_must_be_nonempty';
    end if;
    if new.session_id is distinct from v_charge.session_id then
      raise exception 'assistant_message_session_conflict';
    end if;
    if v_charge.status in ('refunded', 'insufficient_funds') then
      raise exception 'turn_not_allowed_to_deliver_reply';
    end if;
    if v_charge.status = 'settled' then
      raise exception 'turn_already_settled';
    end if;
    if v_charge.status not in ('reserved', 'needs_reconciliation') then
      raise exception 'turn_not_ready_for_reply';
    end if;
  end if;

  return new;
end;
$function$;

revoke all on function public.guard_chat_turn_assistant_insert() from public, anon, authenticated;
grant execute on function public.guard_chat_turn_assistant_insert() to service_role;

drop trigger if exists guard_chat_turn_assistant_insert on public.chat_messages;
create trigger guard_chat_turn_assistant_insert
before insert on public.chat_messages
for each row
when (new.role = 'assistant')
execute function public.guard_chat_turn_assistant_insert();

revoke all on function public.reserve_chat_turn(uuid,uuid,uuid,uuid,uuid) from public, anon, authenticated;
revoke all on function public.settle_chat_turn(uuid,uuid,uuid) from public, anon, authenticated;
revoke all on function public.refund_chat_turn(uuid,uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.reserve_chat_turn(uuid,uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.settle_chat_turn(uuid,uuid,uuid) to service_role;
grant execute on function public.refund_chat_turn(uuid,uuid,uuid,text) to service_role;

commit;
