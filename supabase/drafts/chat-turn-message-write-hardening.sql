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
