-- REVIEW ONLY: atomic hardening for client message writes and charged assistant replies.
-- Do not apply to production without owner approval, isolated test results, and a rollback review.
--
-- Apply this combined transaction rather than either standalone draft:
--   - chat-turn-assistant-update-guard.sql
--   - chat-message-client-insert-policy.sql
-- The browser writes user-authored messages only. The trusted chat-turn Edge Function
-- persists assistant replies with service_role. The character opening is reconstructed
-- from the session snapshot by the frontend and is not inserted by the browser.

begin;

create or replace function public.guard_chat_turn_assistant_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_charge public.chat_turn_charges%rowtype;
  v_locked_charge public.chat_turn_charges%rowtype;
  v_old_charge public.chat_turn_charges%rowtype;
  v_new_charge public.chat_turn_charges%rowtype;
  v_has_old_charge boolean := false;
  v_has_new_charge boolean := false;
begin
  -- A message's semantic role is immutable, including user -> system. Otherwise
  -- a client with UPDATE access could turn player text into a privileged prompt.
  if new.role is distinct from old.role then
    raise exception 'chat_message_role_is_immutable';
  end if;

  if old.role <> 'assistant' then
    return new;
  end if;

  -- Lock matching charge rows in a deterministic ID order. This both detects
  -- cross-turn ID swaps and avoids opposite-order locks for concurrent A<->B swaps.
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

  if not v_has_old_charge and not v_has_new_charge then
    -- Do not allow role escalation to or from assistant without a billable turn.
    if new.role is distinct from old.role
       and (old.role = 'assistant' or new.role = 'assistant') then
      raise exception 'assistant_role_change_requires_chat_turn';
    end if;
    return new;
  end if;

  if new.id is distinct from old.id
     or new.session_id is distinct from old.session_id
     or new.role is distinct from old.role
     or new.content is distinct from old.content then
    raise exception 'charged_assistant_reply_is_immutable';
  end if;

  -- A reply may be soft-deleted only after the charge is settled. While reserved
  -- or awaiting reconciliation, refund logic must still see the persisted reply.
  if new.deleted_at is distinct from old.deleted_at
     and v_old_charge.status is distinct from 'settled' then
    raise exception 'chat_turn_reply_delete_requires_settled_charge';
  end if;

  if not v_has_old_charge
     or old.id is distinct from v_old_charge.expected_assistant_message_id then
    raise exception 'assistant_message_turn_id_conflict';
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
  'Authenticated clients may insert only user-authored messages into their own active chat session. Assistant replies must be persisted by the trusted chat-turn server function.';

commit;

-- Rollback sketch (review before use; never blindly run after data changes):
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
