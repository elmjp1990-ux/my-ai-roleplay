-- Version-control the current chat-turn transaction functions.
-- This migration intentionally preserves the currently verified state machine.
CREATE OR REPLACE FUNCTION public.reserve_chat_turn(p_user_id uuid, p_turn_id uuid, p_session_id uuid, p_user_message_id uuid, p_assistant_message_id uuid)
RETURNS TABLE(turn_id uuid, status text, silver_reserved integer, diamonds_reserved integer, balance_silver integer, balance_diamonds integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
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
  if not exists (select 1 from public.chat_sessions s where s.id = p_session_id and s.user_id = p_user_id and s.deleted_at is null) then
    raise exception 'chat_session_not_owned_or_active';
  end if;
  if not exists (select 1 from public.chat_messages m where m.id = p_user_message_id and m.session_id = p_session_id and m.role = 'user' and m.deleted_at is null) then
    raise exception 'user_message_not_found';
  end if;
  insert into public.chat_turn_charges(turn_id,user_id,session_id,user_message_id,expected_assistant_message_id,cost,status)
  values (p_turn_id,p_user_id,p_session_id,p_user_message_id,p_assistant_message_id,2,'created')
  on conflict (turn_id) do nothing;
  select c.* into v_charge from public.chat_turn_charges c where c.turn_id = p_turn_id for update;
  if v_charge.user_id <> p_user_id or v_charge.session_id <> p_session_id or v_charge.user_message_id <> p_user_message_id or v_charge.expected_assistant_message_id <> p_assistant_message_id then
    raise exception 'turn_id_reuse_conflict';
  end if;
  if v_charge.status <> 'created' then
    select w.silver_coins, w.diamonds into v_silver, v_diamonds from public.wallet_accounts w where w.user_id = p_user_id;
    return query select v_charge.turn_id, v_charge.status, v_charge.silver_reserved, v_charge.diamonds_reserved, v_silver, v_diamonds;
    return;
  end if;
  select w.* into v_wallet from public.wallet_accounts w where w.user_id = p_user_id for update;
  if not found then raise exception 'wallet_not_initialized'; end if;
  if v_wallet.silver_coins + v_wallet.diamonds < 2 then
    update public.chat_turn_charges c set status='insufficient_funds', updated_at=now() where c.turn_id=p_turn_id;
    insert into public.chat_turn_events(turn_id,user_id,event_type,stage,error_code) values (p_turn_id,p_user_id,'insufficient_balance','reservation','insufficient_funds');
    return query select p_turn_id, 'insufficient_funds'::text, 0, 0, v_wallet.silver_coins, v_wallet.diamonds;
    return;
  end if;
  v_silver := least(v_wallet.silver_coins, 2);
  v_diamonds := 2 - v_silver;
  update public.wallet_accounts w set silver_coins=w.silver_coins-v_silver, diamonds=w.diamonds-v_diamonds, updated_at=now() where w.user_id=p_user_id;
  if v_silver > 0 then insert into public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id) values (p_user_id,'silver_coins',-v_silver,'chat_turn_charge',p_turn_id::text); end if;
  if v_diamonds > 0 then insert into public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id) values (p_user_id,'diamonds',-v_diamonds,'chat_turn_charge',p_turn_id::text); end if;
  update public.chat_turn_charges c set status='reserved', silver_reserved=v_silver, diamonds_reserved=v_diamonds, reserved_at=now(), updated_at=now() where c.turn_id=p_turn_id;
  insert into public.chat_turn_events(turn_id,user_id,event_type,stage) values (p_turn_id,p_user_id,'reserved','reservation');
  select w.silver_coins, w.diamonds into v_silver, v_diamonds from public.wallet_accounts w where w.user_id=p_user_id;
  return query select p_turn_id, 'reserved'::text,
    (select c.silver_reserved from public.chat_turn_charges c where c.turn_id=p_turn_id),
    (select c.diamonds_reserved from public.chat_turn_charges c where c.turn_id=p_turn_id), v_silver, v_diamonds;
end;
$function$;

CREATE OR REPLACE FUNCTION public.settle_chat_turn(p_user_id uuid, p_turn_id uuid, p_assistant_message_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare v_charge public.chat_turn_charges%rowtype;
begin
  select c.* into v_charge from public.chat_turn_charges c where c.turn_id=p_turn_id for update;
  if not found or v_charge.user_id <> p_user_id then raise exception 'turn_not_found'; end if;
  if v_charge.expected_assistant_message_id is distinct from p_assistant_message_id then raise exception 'turn_assistant_id_conflict'; end if;
  if v_charge.status = 'settled' then
    if v_charge.assistant_message_id is distinct from p_assistant_message_id then raise exception 'settled_turn_reply_id_conflict'; end if;
    return 'settled';
  end if;
  if v_charge.status not in ('reserved','needs_reconciliation') then raise exception 'turn_not_settleable'; end if;
  if not exists (select 1 from public.chat_messages m where m.id=p_assistant_message_id and m.session_id=v_charge.session_id and m.role='assistant' and m.deleted_at is null and length(btrim(m.content)) > 0) then
    raise exception 'durable_assistant_reply_not_found';
  end if;
  update public.chat_turn_charges c set status='settled', assistant_message_id=p_assistant_message_id, settled_at=now(), updated_at=now() where c.turn_id=p_turn_id;
  insert into public.chat_turn_events(turn_id,user_id,event_type,stage) values (p_turn_id,p_user_id,'settled','persistence');
  return 'settled';
end;
$function$;

CREATE OR REPLACE FUNCTION public.refund_chat_turn(p_user_id uuid, p_turn_id uuid, p_assistant_message_id uuid, p_failure_code text)
RETURNS TABLE(status text, balance_silver integer, balance_diamonds integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare
  v_charge public.chat_turn_charges%rowtype;
  v_wallet public.wallet_accounts%rowtype;
begin
  select c.* into v_charge from public.chat_turn_charges c where c.turn_id=p_turn_id for update;
  if not found or v_charge.user_id <> p_user_id then raise exception 'turn_not_found'; end if;
  if v_charge.expected_assistant_message_id is distinct from p_assistant_message_id then raise exception 'turn_assistant_id_conflict'; end if;
  if v_charge.status = 'refunded' then
    select w.silver_coins,w.diamonds into v_wallet.silver_coins,v_wallet.diamonds from public.wallet_accounts w where w.user_id=p_user_id;
    return query select 'refunded'::text,v_wallet.silver_coins,v_wallet.diamonds;
    return;
  end if;
  if v_charge.status = 'settled' then raise exception 'settled_turn_cannot_be_refunded'; end if;
  if v_charge.status not in ('reserved','needs_reconciliation') then raise exception 'turn_not_refundable'; end if;
  if p_assistant_message_id is not null and exists (
    select 1 from public.chat_messages m where m.id=p_assistant_message_id and m.session_id=v_charge.session_id and m.role='assistant' and m.deleted_at is null and length(btrim(m.content)) > 0
  ) then raise exception 'reply_already_persisted'; end if;
  select w.* into v_wallet from public.wallet_accounts w where w.user_id=p_user_id for update;
  if not found then raise exception 'wallet_not_initialized'; end if;
  update public.wallet_accounts w set silver_coins=w.silver_coins+v_charge.silver_reserved, diamonds=w.diamonds+v_charge.diamonds_reserved, updated_at=now() where w.user_id=p_user_id;
  if v_charge.silver_reserved > 0 then insert into public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id) values (p_user_id,'silver_coins',v_charge.silver_reserved,'chat_turn_refund',p_turn_id::text); end if;
  if v_charge.diamonds_reserved > 0 then insert into public.wallet_transactions(user_id,currency_type,amount,biz_type,reference_id) values (p_user_id,'diamonds',v_charge.diamonds_reserved,'chat_turn_refund',p_turn_id::text); end if;
  update public.chat_turn_charges c set status='refunded', failure_code=left(coalesce(p_failure_code,'confirmed_failure'),80), refunded_at=now(), updated_at=now() where c.turn_id=p_turn_id;
  insert into public.chat_turn_events(turn_id,user_id,event_type,stage,error_code) values (p_turn_id,p_user_id,'refunded','recovery',left(coalesce(p_failure_code,'confirmed_failure'),80));
  select w.silver_coins,w.diamonds into v_wallet.silver_coins,v_wallet.diamonds from public.wallet_accounts w where w.user_id=p_user_id;
  return query select 'refunded'::text,v_wallet.silver_coins,v_wallet.diamonds;
end;
$function$;

CREATE OR REPLACE FUNCTION public.guard_chat_turn_assistant_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare v_charge public.chat_turn_charges%rowtype;
begin
  if new.role <> 'assistant' then return new; end if;
  select c.* into v_charge from public.chat_turn_charges c where c.expected_assistant_message_id = new.id for update;
  if found then
    if length(btrim(coalesce(new.content, ''))) = 0 then raise exception 'assistant_reply_must_be_nonempty'; end if;
    if new.session_id is distinct from v_charge.session_id then raise exception 'assistant_message_session_conflict'; end if;
    if v_charge.status in ('refunded', 'insufficient_funds') then raise exception 'turn_not_allowed_to_deliver_reply'; end if;
    if v_charge.status = 'settled' then raise exception 'turn_already_settled'; end if;
    if v_charge.status not in ('reserved', 'needs_reconciliation') then raise exception 'turn_not_ready_for_reply'; end if;
  end if;
  return new;
end;
$function$;
