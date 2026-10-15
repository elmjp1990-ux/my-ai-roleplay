-- Chat-turn assistant reply immutability hardening.
-- REVIEW ONLY: do not apply to production without owner approval.
-- The current INSERT guard does not protect a paid assistant reply from later
-- UPDATEs through the existing chat_messages_update_own policy.
-- This trigger permits soft-delete metadata changes but prevents changing the
-- reply identity, session, role, or content once its ID is registered to a turn.

create or replace function public.guard_chat_turn_assistant_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_charge public.chat_turn_charges%rowtype;
begin
  -- Superseded standalone reference: role changes must never promote
  -- player-controlled content to system/assistant semantics.
  if new.role is distinct from old.role then
    raise exception 'chat_message_role_is_immutable';
  end if;

  if old.role <> 'assistant' then
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
    -- Prevent a client from converting an ordinary user message into a fake
    -- assistant reply (or converting an uncharged assistant row into another role).
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
