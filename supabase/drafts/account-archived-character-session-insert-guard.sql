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
  v_character_unavailable boolean;
BEGIN
  v_character_id := NULLIF(COALESCE(
    pg_catalog.to_jsonb(NEW) ->> 'character_id',
    pg_catalog.to_jsonb(NEW) ->> 'world_character_id'
  ), '')::uuid;

  -- Legacy conversations reference character_stories rather than characters.
  -- Lock the owning character too, or a conversation INSERT could race a
  -- hard-delete and then be cascaded away through story_id.
  IF v_character_id IS NULL THEN
    SELECT cs.character_id
      INTO v_character_id
    FROM public.character_stories AS cs
    WHERE cs.id = NULLIF(pg_catalog.to_jsonb(NEW) ->> 'story_id', '')::uuid;
  END IF;

  IF v_character_id IS NOT NULL THEN
    -- Serialize new-entry creation with soft_delete_character()'s FOR UPDATE
    -- lock. If the insert wins, deletion waits and its history check sees the
    -- committed parent. If deletion wins, this insert waits and then fails.
    SELECT (c.deleted_at IS NOT NULL OR c.account_archived_at IS NOT NULL)
      INTO v_character_unavailable
    FROM public.characters AS c
    WHERE c.id = v_character_id
    FOR KEY SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'character_not_available'
        USING ERRCODE = '42501';
    END IF;

    IF v_character_unavailable IS TRUE THEN
      RAISE EXCEPTION 'character_not_available'
        USING ERRCODE = '42501';
    END IF;
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
  BEFORE INSERT OR UPDATE OF character_id ON public.chat_sessions
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

DROP TRIGGER IF EXISTS reject_archived_character_new_world_group
  ON public.chat_groups;
CREATE TRIGGER reject_archived_character_new_world_group
  BEFORE INSERT OR UPDATE OF world_character_id ON public.chat_groups
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

DROP TRIGGER IF EXISTS reject_archived_character_new_group_member
  ON public.chat_group_members;
CREATE TRIGGER reject_archived_character_new_group_member
  BEFORE INSERT OR UPDATE OF character_id ON public.chat_group_members
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

DROP TRIGGER IF EXISTS reject_archived_character_new_encounter
  ON public.encounter_session_lifecycle;
CREATE TRIGGER reject_archived_character_new_encounter
  BEFORE INSERT OR UPDATE OF character_id ON public.encounter_session_lifecycle
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

DROP TRIGGER IF EXISTS reject_archived_character_new_story
  ON public.story_relationship_states;
CREATE TRIGGER reject_archived_character_new_story
  BEFORE INSERT OR UPDATE OF character_id ON public.story_relationship_states
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

-- Legacy conversations have no direct character_id FK: they point to a story,
-- which then cascades from characters. Guard story_id writes explicitly so
-- history-aware hard deletion cannot race and cascade away a newly inserted chat.
DROP TRIGGER IF EXISTS reject_archived_character_legacy_conversation
  ON public.conversations;
CREATE TRIGGER reject_archived_character_legacy_conversation
  BEFORE INSERT OR UPDATE OF story_id ON public.conversations
  FOR EACH ROW
  EXECUTE FUNCTION private.reject_account_archived_character_entry();

-- Existing legacy messages are continuation writes and are deliberately not
-- guarded. Only creating/reassigning the conversation parent is blocked.

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
