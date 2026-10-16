-- Allow history upserts of an already-persisted assistant message.
-- PostgREST INSERT ... ON CONFLICT still runs BEFORE INSERT triggers before
-- resolving the conflict. Without this guard, a settled charge rejects
-- ordinary chat history sync as turn_already_settled.
CREATE OR REPLACE FUNCTION public.guard_chat_turn_assistant_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_charge public.chat_turn_charges%rowtype;
begin
  if new.role <> 'assistant' then
    return new;
  end if;

  if exists (
    select 1
    from public.chat_messages m
    where m.id = new.id
  ) then
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
