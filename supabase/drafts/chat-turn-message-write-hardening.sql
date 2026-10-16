-- REVIEW ONLY: atomic hardening for client message writes and assistant replies.
-- Do not apply until isolated tests pass and rollback has been reviewed.
--
-- Browser clients may write user-authored messages only. The trusted chat-turn
-- Edge Function creates assistant replies after reservation. Players MAY edit
-- the displayed content of a persisted assistant reply; the existing
-- chat_messages_save_version_before_update trigger must preserve each prior
-- content value in chat_message_versions. This guard protects identity/role and
-- billing state, not the player's ability to edit their own conversation.

begin;

create or replace function public.guard_chat_turn_assistant_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_locked_charge public.chat_turn_charges%rowtype;
  v_old_charge public.chat_turn_charges%rowtype;
  v_new_charge public.chat_turn_charges%rowtype;
  v_has_old_charge boolean := false;
  v_has_new_charge boolean := false;
  v_content_changed boolean;
  v_deleted_changed boolean;
begin
  -- Never let a client change prompt semantics (user/system/assistant).
  if new.role is distinct from old.role then
    raise exception 'chat_message_role_is_immutable';
  end if;

  -- IDs and session ownership are stable for every message, including user
  -- messages. Content editing is a separate operation from identity changes.
  if new.id is distinct from old.id
     or new.session_id is distinct from old.session_id then
    if old.role = 'assistant' then
      raise exception 'assistant_message_identity_is_immutable';
    else
      raise exception 'user_message_identity_is_immutable';
    end if;
  end if;

  if old.role <> 'assistant' then
    return new;
  end if;

  v_content_changed := new.content is distinct from old.content;
  v_deleted_changed := new.deleted_at is distinct from old.deleted_at;

  -- Lock every charge row tied to either identity in deterministic order. This
  -- detects cross-turn ID swaps and serializes edits against settlement/refund.
  for v_locked_charge in
    select c.*
    from public.chat_turn_charges c
    where c.expected_assistant_message_id = old.id
       or c.expected_assistant_message_id = new.id
    order by c.expected_assistant_message_id
    for update
  loop
    if v_locked_charge.expected_assistant_message_id = old.id then
      v_old_charge := v_locked_charge;
      v_has_old_charge := true;
    end if;
    if v_locked_charge.expected_assistant_message_id = new.id then
      v_new_charge := v_locked_charge;
      v_has_new_charge := true;
    end if;
  end loop;

  if v_has_old_charge and v_has_new_charge
     and v_old_charge.turn_id is distinct from v_new_charge.turn_id then
    raise exception 'assistant_message_turn_id_conflict';
  end if;

  if v_has_old_charge
     and old.id is distinct from v_old_charge.expected_assistant_message_id then
    raise exception 'assistant_message_turn_id_conflict';
  end if;

  -- Do not combine hiding a reply with content edits. A soft delete is allowed
  -- only after settlement; reserved/unresolved replies must remain visible to
  -- reconciliation so they cannot be mistaken for a missing generation.
  if v_deleted_changed then
    if v_content_changed then
      raise exception 'assistant_reply_edit_and_delete_must_be_separate';
    end if;
    if v_has_old_charge and v_old_charge.status is distinct from 'settled' then
      raise exception 'chat_turn_reply_delete_requires_settled_charge';
    end if;
    return new;
  end if;

  -- Editing a charged reply is a supported player feature, but only after the
  -- turn has settled. The existing version trigger stores OLD.content in the
  -- same transaction before the update; if this guard raises, that insert rolls
  -- back too. Legacy assistant rows without a charge ledger remain editable as
  -- well, with the same version-history trigger.
  if v_content_changed and v_has_old_charge
     and v_old_charge.status is distinct from 'settled' then
    raise exception 'assistant_reply_edit_requires_settled_charge';
  end if;

  return new;
end;
$function$;

revoke all on function public.guard_chat_turn_assistant_update() from public, anon, authenticated;
grant execute on function public.guard_chat_turn_assistant_update() to service_role;

drop trigger if exists guard_chat_turn_assistant_update on public.chat_messages;
create trigger guard_chat_turn_assistant_update
before update of id, session_id, role, content, deleted_at on public.chat_messages
for each row
execute function public.guard_chat_turn_assistant_update();

create or replace function public.refund_chat_turn(
  p_user_id uuid,
  p_turn_id uuid,
  p_assistant_message_id uuid,
  p_failure_code text
)
returns table(status text, balance_silver integer, balance_diamonds integer)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_charge public.chat_turn_charges%rowtype;
  v_wallet public.wallet_accounts%rowtype;
begin
  select c.* into v_charge
  from public.chat_turn_charges c
  where c.turn_id = p_turn_id
  for update;

  if not found or v_charge.user_id <> p_user_id then
    raise exception 'turn_not_found';
  end if;
  if v_charge.expected_assistant_message_id is distinct from p_assistant_message_id then
    raise exception 'turn_assistant_id_conflict';
  end if;

  -- Idempotent retry after an already completed refund never credits twice.
  if v_charge.status = 'refunded' then
    select w.silver_coins, w.diamonds
      into v_wallet.silver_coins, v_wallet.diamonds
    from public.wallet_accounts w
    where w.user_id = p_user_id;
    return query select 'refunded'::text, v_wallet.silver_coins, v_wallet.diamonds;
    return;
  end if;

  if v_charge.status = 'settled' then
    raise exception 'settled_turn_cannot_be_refunded';
  end if;
  if v_charge.status not in ('reserved', 'needs_reconciliation') then
    raise exception 'turn_not_refundable';
  end if;

  -- Fail closed: any persisted row occupying the expected assistant message ID
  -- blocks automatic refund, even if it is soft-deleted, empty, or has a
  -- mismatched role/session. Such a state requires explicit reconciliation.
  if p_assistant_message_id is not null and exists (
    select 1
    from public.chat_messages m
    where m.id = p_assistant_message_id
  ) then
    raise exception 'reply_already_persisted_or_integrity_conflict';
  end if;

  select w.* into v_wallet
  from public.wallet_accounts w
  where w.user_id = p_user_id
  for update;
  if not found then
    raise exception 'wallet_not_initialized';
  end if;

  update public.wallet_accounts w
  set silver_coins = w.silver_coins + v_charge.silver_reserved,
      diamonds = w.diamonds + v_charge.diamonds_reserved,
      updated_at = now()
  where w.user_id = p_user_id;

  if v_charge.silver_reserved > 0 then
    insert into public.wallet_transactions(user_id, currency_type, amount, biz_type, reference_id)
    values (p_user_id, 'silver_coins', v_charge.silver_reserved, 'chat_turn_refund', p_turn_id::text);
  end if;
  if v_charge.diamonds_reserved > 0 then
    insert into public.wallet_transactions(user_id, currency_type, amount, biz_type, reference_id)
    values (p_user_id, 'diamonds', v_charge.diamonds_reserved, 'chat_turn_refund', p_turn_id::text);
  end if;

  update public.chat_turn_charges c
  set status = 'refunded',
      failure_code = left(coalesce(p_failure_code, 'confirmed_failure'), 80),
      refunded_at = now(),
      updated_at = now()
  where c.turn_id = p_turn_id;

  insert into public.chat_turn_events(turn_id, user_id, event_type, stage, error_code)
  values (p_turn_id, p_user_id, 'refunded', 'recovery',
          left(coalesce(p_failure_code, 'confirmed_failure'), 80));

  select w.silver_coins, w.diamonds
    into v_wallet.silver_coins, v_wallet.diamonds
  from public.wallet_accounts w
  where w.user_id = p_user_id;

  return query select 'refunded'::text, v_wallet.silver_coins, v_wallet.diamonds;
end;
$function$;

revoke all on function public.refund_chat_turn(uuid, uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.refund_chat_turn(uuid, uuid, uuid, text) to service_role;

-- RLS does not constrain service_role, so assistant-row integrity must be
-- enforced by a database trigger as well as the authenticated INSERT policy.
-- Lock the charge row before allowing an assistant INSERT; this shares the
-- charge-row serialization point with refund_chat_turn().
create or replace function public.guard_chat_turn_assistant_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_charge public.chat_turn_charges%rowtype;
begin
  -- If this ID is already reserved as a turn's expected assistant ID, no
  -- other role/session may occupy it. This also fails closed on ID collisions.
  select c.* into v_charge
  from public.chat_turn_charges c
  where c.expected_assistant_message_id = new.id
  for update;

  if found then
    if new.role is distinct from 'assistant' then
      raise exception 'expected_assistant_message_id_role_conflict';
    end if;
    if new.session_id is distinct from v_charge.session_id then
      raise exception 'expected_assistant_message_session_conflict';
    end if;
    if v_charge.status not in ('reserved', 'needs_reconciliation') then
      raise exception 'assistant_insert_requires_unresolved_charge';
    end if;
    if char_length(btrim(coalesce(new.content, ''))) = 0 then
      raise exception 'assistant_reply_content_required';
    end if;
    return new;
  end if;

  -- No client or service-role path may create an assistant reply outside the
  -- billable turn ledger. Character openings are snapshot-only, not chat rows.
  if new.role = 'assistant' then
    raise exception 'assistant_reply_requires_chat_turn';
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
execute function public.guard_chat_turn_assistant_insert();

drop policy if exists chat_messages_insert_own on public.chat_messages;

create policy chat_messages_insert_own
on public.chat_messages
for insert
to authenticated
with check (
  role = 'user'
  and (select public.account_is_active())
  and exists (
    select 1
    from public.chat_sessions s
    where s.id = chat_messages.session_id
      and s.user_id = (select auth.uid())
      and s.deleted_at is null
  )
);

comment on policy chat_messages_insert_own on public.chat_messages is
  'Authenticated clients may insert only user-authored messages into their own active chat session. Assistant replies must be created by the trusted chat-turn server function.';

commit;

-- Rollback sketch (review before use; do not blindly run after data changes):
-- begin;
-- drop trigger if exists guard_chat_turn_assistant_update on public.chat_messages;
-- drop function if exists public.guard_chat_turn_assistant_update();
-- drop policy if exists chat_messages_insert_own on public.chat_messages;
-- create policy chat_messages_insert_own on public.chat_messages
-- for insert to authenticated
-- with check (
--   (select public.account_is_active())
--   and exists (
--     select 1 from public.chat_sessions s
--     where s.id = chat_messages.session_id
--       and s.user_id = (select auth.uid())
--   )
-- );
-- commit;
