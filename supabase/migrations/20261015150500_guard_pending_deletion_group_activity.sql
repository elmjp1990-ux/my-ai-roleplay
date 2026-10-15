-- Prevent accounts with a pending deletion request from creating new group chats
-- or appending new group turns, even when calling SECURITY DEFINER RPCs directly.
CREATE OR REPLACE FUNCTION public.guard_pending_account_group_activity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'chat_groups' THEN
    v_user_id := NEW.owner_id;
  ELSIF TG_TABLE_NAME = 'chat_group_turns' THEN
    v_user_id := NEW.user_id;
  ELSE
    RAISE EXCEPTION 'unsupported_group_activity_table';
  END IF;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'group_activity_user_required' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.account_deletion_requests AS r
    WHERE r.user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.guard_pending_account_group_activity() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_pending_account_group_activity() FROM anon, authenticated;

DROP TRIGGER IF EXISTS guard_pending_deletion_chat_group_insert ON public.chat_groups;
CREATE TRIGGER guard_pending_deletion_chat_group_insert
BEFORE INSERT ON public.chat_groups
FOR EACH ROW
EXECUTE FUNCTION public.guard_pending_account_group_activity();

DROP TRIGGER IF EXISTS guard_pending_deletion_chat_group_turn_insert ON public.chat_group_turns;
CREATE TRIGGER guard_pending_deletion_chat_group_turn_insert
BEFORE INSERT ON public.chat_group_turns
FOR EACH ROW
EXECUTE FUNCTION public.guard_pending_account_group_activity();
