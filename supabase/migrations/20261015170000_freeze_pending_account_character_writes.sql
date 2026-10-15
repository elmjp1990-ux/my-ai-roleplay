-- Freeze character and chat-session mutations while the authenticated owner
-- has a pending account deletion request. This also covers SECURITY DEFINER
-- RPCs because the checks run at the table-write boundary.
CREATE OR REPLACE FUNCTION public.guard_pending_account_character_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_owner_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_owner_id := OLD.author_id;
  ELSE
    v_owner_id := NEW.author_id;
  END IF;

  IF auth.uid() IS NOT NULL
     AND auth.uid() = v_owner_id
     AND EXISTS (
       SELECT 1
       FROM public.account_deletion_requests AS r
       WHERE r.user_id = v_owner_id
     ) THEN
    RAISE EXCEPTION 'account_deletion_pending'
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.guard_pending_account_character_write()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS guard_pending_account_character_write
  ON public.characters;
CREATE TRIGGER guard_pending_account_character_write
  BEFORE INSERT OR UPDATE OR DELETE ON public.characters
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_pending_account_character_write();

CREATE OR REPLACE FUNCTION public.guard_pending_account_chat_session_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL
     AND auth.uid() = OLD.user_id
     AND EXISTS (
       SELECT 1
       FROM public.account_deletion_requests AS r
       WHERE r.user_id = OLD.user_id
     ) THEN
    RAISE EXCEPTION 'account_deletion_pending'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.guard_pending_account_chat_session_update()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS guard_pending_account_chat_session_update
  ON public.chat_sessions;
CREATE TRIGGER guard_pending_account_chat_session_update
  BEFORE UPDATE ON public.chat_sessions
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_pending_account_chat_session_update();
