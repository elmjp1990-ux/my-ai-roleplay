-- DRAFT ONLY — NOT AN ACTIVE MIGRATION.
-- Defense-in-depth for account-archived characters.
-- Requires public.characters.account_archived_at from
-- account-deletion-character-preservation-draft.sql.
-- Do not execute against hosted Supabase until baseline provenance and local
-- PostgreSQL replay are complete.

-- Edge Functions already perform caller-JWT eligibility checks, but trusted
-- service-role creation RPCs are privileged entrypoints. Enforce the archive
-- state again at the database INSERT boundary so a future Edge/RPC regression
-- cannot create a new conversation for an account-archived character.
CREATE OR REPLACE FUNCTION private.reject_account_archived_character_entry()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_character_id uuid;
BEGIN
  v_character_id := NULLIF(pg_catalog.to_jsonb(NEW) ->> 'character_id', '')::uuid;

  IF v_character_id IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.characters AS c
       WHERE c.id = v_character_id
         AND c.account_archived_at IS NOT NULL
     ) THEN
    RAISE EXCEPTION 'character_account_archived'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.reject_account_archived_character_entry()
  FROM PUBLIC, anon, authenticated, service_role;

-- Single chat, encounter, story, and group membership are all new-entry writes.
-- Existing chat continuation writes to message/turn tables and is deliberately
-- not guarded here.
DROP TRIGGER IF EXISTS reject_archived_character_new_chat
  ON public.chat_sessions;
CREATE TRIGGER reject_archived_character_new_chat
  BEFORE INSERT ON public.chat_sessions
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

DROP TRIGGER IF EXISTS reject_archived_character_new_group_member
  ON public.chat_group_members;
CREATE TRIGGER reject_archived_character_new_group_member
  BEFORE INSERT ON public.chat_group_members
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

DROP TRIGGER IF EXISTS reject_archived_character_new_encounter
  ON public.encounter_session_lifecycle;
CREATE TRIGGER reject_archived_character_new_encounter
  BEFORE INSERT ON public.encounter_session_lifecycle
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

DROP TRIGGER IF EXISTS reject_archived_character_new_story
  ON public.story_relationship_states;
CREATE TRIGGER reject_archived_character_new_story
  BEFORE INSERT ON public.story_relationship_states
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

-- Regression requirements for disposable PostgreSQL:
-- 1. Account archive marker set: INSERT chat_sessions for that character fails.
-- 2. Account archive marker set: INSERT chat_group_members fails.
-- 3. Account archive marker set: INSERT encounter_session_lifecycle fails.
-- 4. Account archive marker set: INSERT story_relationship_states fails.
-- 5. Existing chat_messages / chat_group_messages / encounter turns can continue
--    for their already-authorized, non-deleted parent; no trigger is attached to
--    these continuation tables.
-- 6. Non-archived characters preserve existing creation behavior.
-- 7. A failure in any parent/child insert transaction rolls back all rows.
