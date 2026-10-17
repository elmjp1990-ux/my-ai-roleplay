-- Source-only draft: atomic persistence for a billable chat reply.
-- DO NOT apply to the connected database yet. Review and test in an isolated
-- Supabase project first. This function is intended to replace separate
-- ai_generation_records INSERT + chat_messages INSERT calls in chat-turn.
--
-- Invariants:
-- 1. The charge row is locked and the supplied IDs must match its reserved turn.
-- 2. Assistant message and generation identity are inserted in ONE transaction.
-- 3. chat_messages is inserted first to satisfy the generation-record FK.
-- 4. Any failure (including unique/FK/trigger failure) rolls back both inserts.
-- 5. A retry is idempotent only if BOTH durable rows already exist and identity
--    matches exactly. A lone assistant row is never retroactively claimed.

create or replace function public.persist_chat_turn_reply(
  p_user_id uuid,
  p_turn_id uuid,
  p_session_id uuid,
  p_user_message_id uuid,
  p_assistant_message_id uuid,
  p_content text
)
returns table(
  status text,
  assistant_message_id uuid,
  assistant_content text,
  idempotent boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_charge public.chat_turn_charges%rowtype;
  v_message public.chat_messages%rowtype;
  v_generation public.ai_generation_records%rowtype;
  v_has_message boolean := false;
  v_has_generation boolean := false;
begin
  if p_user_id is null
     or p_turn_id is null
     or p_session_id is null
     or p_user_message_id is null
     or p_assistant_message_id is null
     or char_length(btrim(coalesce(p_content, ''))) = 0 then
    raise exception 'invalid_reply_persistence_request';
  end if;

  select c.* into v_charge
  from public.chat_turn_charges c
  where c.turn_id = p_turn_id
  for update;

  if not found
     or v_charge.user_id is distinct from p_user_id
     or v_charge.session_id is distinct from p_session_id
     or v_charge.user_message_id is distinct from p_user_message_id
     or v_charge.expected_assistant_message_id is distinct from p_assistant_message_id then
    raise exception 'chat_turn_identity_conflict';
  end if;

  if v_charge.status not in ('reserved', 'needs_reconciliation') then
    raise exception 'chat_turn_not_persistable';
  end if;

  if not exists (
    select 1
    from public.chat_sessions s
    where s.id = p_session_id
      and s.user_id = p_user_id
      and s.deleted_at is null
  ) then
    raise exception 'chat_session_not_owned_or_active';
  end if;

  if not exists (
    select 1
    from public.chat_messages m
    where m.id = p_user_message_id
      and m.session_id = p_session_id
      and m.role = 'user'
      and m.deleted_at is null
      and char_length(btrim(m.content)) > 0
  ) then
    raise exception 'user_message_not_found';
  end if;

  select m.* into v_message
  from public.chat_messages m
  where m.id = p_assistant_message_id;
  v_has_message := found;

  select g.* into v_generation
  from public.ai_generation_records g
  where g.assistant_message_id = p_assistant_message_id;
  v_has_generation := found;

  if v_has_message or v_has_generation then
    if not (v_has_message and v_has_generation) then
      raise exception 'partial_reply_identity_requires_reconciliation';
    end if;

    if v_message.session_id is distinct from p_session_id
       or v_message.role is distinct from 'assistant'
       or v_message.deleted_at is not null
       or char_length(btrim(coalesce(v_message.content, ''))) = 0
       or v_generation.user_id is distinct from p_user_id
       or v_generation.session_id is distinct from p_session_id
       or v_generation.user_message_id is distinct from p_user_message_id
       or v_generation.assistant_message_id is distinct from p_assistant_message_id
       or v_generation.request_id is distinct from p_turn_id
       or char_length(btrim(coalesce(v_generation.original_content, ''))) = 0 then
      raise exception 'assistant_message_id_collision';
    end if;

    return query
      select 'persisted'::text, v_message.id, v_message.content, true;
    return;
  end if;

  -- The BEFORE INSERT guard locks/validates the same charge row and requires
  -- a non-empty assistant message for this unresolved turn.
  insert into public.chat_messages(id, session_id, role, content)
  values (p_assistant_message_id, p_session_id, 'assistant', p_content)
  returning * into v_message;

  -- FK assistant_message_id now points at the row inserted above. If this
  -- insert or any constraint fails, PostgreSQL rolls back the message too.
  insert into public.ai_generation_records(
    user_id, session_id, user_message_id, assistant_message_id,
    request_id, original_content, status
  ) values (
    p_user_id, p_session_id, p_user_message_id, p_assistant_message_id,
    p_turn_id, p_content, 'success'
  );

  return query
    select 'persisted'::text, v_message.id, v_message.content, false;
end;
$function$;

revoke all on function public.persist_chat_turn_reply(uuid, uuid, uuid, uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.persist_chat_turn_reply(uuid, uuid, uuid, uuid, uuid, text)
  to service_role;
