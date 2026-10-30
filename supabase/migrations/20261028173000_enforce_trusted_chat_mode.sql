-- Enforce server-owned chat mode even when clients have table-level INSERT/UPDATE grants.
-- Column-level REVOKE alone cannot override an existing table-level privilege.
CREATE OR REPLACE FUNCTION public.enforce_trusted_chat_mode()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    IF TG_OP = 'INSERT' THEN
      NEW.chat_mode := 'story';
    ELSIF NEW.chat_mode IS DISTINCT FROM OLD.chat_mode THEN
      RAISE EXCEPTION 'chat_mode is server-managed'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_trusted_chat_mode() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS chat_sessions_enforce_trusted_chat_mode ON public.chat_sessions;
CREATE TRIGGER chat_sessions_enforce_trusted_chat_mode
BEFORE INSERT OR UPDATE OF chat_mode ON public.chat_sessions
FOR EACH ROW
EXECUTE FUNCTION public.enforce_trusted_chat_mode();

COMMENT ON FUNCTION public.enforce_trusted_chat_mode() IS
  'Prevents client roles from creating or upgrading sessions into Encounter mode. Only service-role backend may set chat_mode=encounter.';
