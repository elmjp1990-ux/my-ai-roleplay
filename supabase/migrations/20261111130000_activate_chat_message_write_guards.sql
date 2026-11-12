-- PR #29 security migration port, rebased onto current main.
-- The current main already versions the full guard_chat_turn_assistant_update()
-- function (including parent-session locking and the authorized purge-worker
-- bypass) in 20261101055617_chat_deletion_purge_worker_rpc.sql.
-- This migration activates that guard as a trigger and closes the browser
-- INSERT role boundary. It intentionally does not replace current chat-turn
-- Edge code or wallet RPC implementations.

begin;

-- Attach the already-versioned UPDATE guard. It protects role and identity for
-- every message, and prevents editing/hiding an assistant reply before charge
-- settlement. The function also permits the narrowly scoped service-role purge
-- worker path used by the existing 14-day deletion lifecycle.
drop trigger if exists guard_chat_turn_assistant_update on public.chat_messages;
create trigger guard_chat_turn_assistant_update
before update of id, session_id, role, content, deleted_at
on public.chat_messages
for each row
execute function public.guard_chat_turn_assistant_update();

-- RLS policies are permissive by default; replace the known owner INSERT policy
-- so browser clients can create only their own user-authored messages.
-- The BEFORE INSERT assistant guard remains the second boundary because
-- service_role bypasses RLS.
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

-- Message chronology is part of the durable transcript. This invoker-only
-- guard has no privileged reads or writes: it rejects timestamp changes without
-- taking a parent lock or adding a query to normal message writes.
CREATE OR REPLACE FUNCTION public.guard_chat_message_created_at_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
  IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'chat_message_created_at_is_immutable';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS guard_chat_message_created_at_update ON public.chat_messages;
CREATE TRIGGER guard_chat_message_created_at_update
BEFORE UPDATE OF created_at
ON public.chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.guard_chat_message_created_at_update();

-- Trigger functions do not need direct browser-role EXECUTE grants to run
-- through table triggers. The timestamp guard is SECURITY INVOKER; the two
-- assistant guards are SECURITY DEFINER. Keep direct invocation privileges
-- limited to the trusted server role.
REVOKE ALL ON FUNCTION public.guard_chat_turn_assistant_insert() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guard_chat_turn_assistant_insert() TO service_role;
REVOKE ALL ON FUNCTION public.guard_chat_turn_assistant_update() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guard_chat_turn_assistant_update() TO service_role;
REVOKE ALL ON FUNCTION public.guard_chat_message_created_at_update() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guard_chat_message_created_at_update() TO service_role;

commit;
