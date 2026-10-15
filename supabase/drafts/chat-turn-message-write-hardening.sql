-- REVIEW ONLY: atomic hardening for client message writes and charged assistant replies.
-- Do not apply to production without owner approval, isolated test results, and a rollback review.
--
-- Apply this combined transaction rather than either standalone draft:
--   - chat-turn-assistant-update-guard.sql
--   - chat-message-client-insert-policy.sql
-- It closes the gap where a client can insert an arbitrary assistant-role row and
-- avoids a window in which client INSERT restrictions exist without reply UPDATE guards.
--
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
begin
  if old.role <> 'assistant' and new.role <> 'assistant' then
    return new;
  end if;

  select c.* into v_charge
  from public.chat_turn_charges c
  where c.expected_assistant_message_id = old.id
     or c.expected_assistant_message_id = new.id
  order by c.created_at
  limit 1
  for update;

  if not found then
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

  if old.id is distinct from v_charge.expected_assistant_message_id then
    raise exception 'assistant_message_turn_id_conflict';
  end if;

  return new;
end;
$function$;

revoke all on function public.guard_chat_turn_assistant_update() from public, anon, authenticated;
grant execute on function public.guard_chat_turn_assistant_update() to service_role;

drop trigger if exists guard_chat_turn_assistant_update on public.chat_messages;
create trigger guard_chat_turn_assistant_update
before update of id, session_id, role, content on public.chat_messages
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
