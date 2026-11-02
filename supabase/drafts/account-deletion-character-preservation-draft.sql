-- DRAFT ONLY — NOT AN ACTIVE MIGRATION.
-- Account deletion must preserve every character and all of its child data/media.
-- Do not execute this file against the hosted Supabase project.
-- Reconcile the full migration ledger and test this on a disposable local database first.
--
-- This draft is based on read-only catalog inspection from 2026-11-02.
-- It is intentionally separated from supabase/migrations/ until all callers/tests are ready.

-- 1) Durable, non-clickable creator attribution and explicit account archive marker.
ALTER TABLE public.characters
  ADD COLUMN IF NOT EXISTS creator_display_name text,
  ADD COLUMN IF NOT EXISTS creator_handle_snapshot text,
  ADD COLUMN IF NOT EXISTS account_archived_at timestamptz;

COMMENT ON COLUMN public.characters.creator_display_name IS
  'Plain-text historical creator attribution; not a profile link.';
COMMENT ON COLUMN public.characters.creator_handle_snapshot IS
  'Plain-text historical creator handle; not a profile link.';
COMMENT ON COLUMN public.characters.account_archived_at IS
  'Set when the creator account is deleted; blocks all new sessions while preserving existing sessions.';

-- 2) Detach active ownership instead of cascading character content away.
-- Keep profiles.id -> auth.users(id) ON DELETE CASCADE unchanged.
ALTER TABLE public.characters ALTER COLUMN author_id DROP NOT NULL;
ALTER TABLE public.characters DROP CONSTRAINT IF EXISTS characters_author_id_fkey;
ALTER TABLE public.characters
  ADD CONSTRAINT characters_author_id_fkey
  FOREIGN KEY (author_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.character_private_info ALTER COLUMN author_id DROP NOT NULL;
ALTER TABLE public.character_private_info DROP CONSTRAINT IF EXISTS character_private_info_author_id_fkey;
ALTER TABLE public.character_private_info
  ADD CONSTRAINT character_private_info_author_id_fkey
  FOREIGN KEY (author_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.character_illustrations ALTER COLUMN author_id DROP NOT NULL;
ALTER TABLE public.character_illustrations DROP CONSTRAINT IF EXISTS character_illustrations_author_id_fkey;
ALTER TABLE public.character_illustrations
  ADD CONSTRAINT character_illustrations_author_id_fkey
  FOREIGN KEY (author_id) REFERENCES public.profiles(id) ON DELETE SET NULL;

-- This table references auth.users directly, not profiles.
ALTER TABLE public.character_schedule_descriptions ALTER COLUMN author_id DROP NOT NULL;
ALTER TABLE public.character_schedule_descriptions
  DROP CONSTRAINT IF EXISTS character_schedule_descriptions_author_id_fkey;
ALTER TABLE public.character_schedule_descriptions
  ADD CONSTRAINT character_schedule_descriptions_author_id_fkey
  FOREIGN KEY (author_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- 3) Narrow existing-session authorization. This deliberately ignores current
-- character visibility/deleted_at: existing session owners may continue and load
-- the character's exact media; users without a prior session get false.
CREATE OR REPLACE FUNCTION private.user_has_existing_character_session(
  p_character_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT auth.uid() IS NOT NULL
    AND p_character_id IS NOT NULL
    AND (
      EXISTS (
        SELECT 1
        FROM public.chat_sessions AS s
        WHERE s.character_id = p_character_id
          AND s.user_id = auth.uid()
          AND s.deleted_at IS NULL
      )
      OR EXISTS (
        SELECT 1
        FROM public.chat_group_members AS gm
        JOIN public.chat_groups AS g
          ON g.id = gm.group_id
        WHERE gm.character_id = p_character_id
          AND g.owner_id = auth.uid()
          -- archived_at only hides a group from the active list; it is not deletion.
          -- An archived group remains an existing conversation and retains access.
          AND g.deleted_at IS NULL
      )
    );
$function$;

REVOKE ALL ON FUNCTION private.user_has_existing_character_session(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.user_has_existing_character_session(uuid)
  TO authenticated;

-- 4) Storage policy helper: exact path must be referenced by the character row
-- or illustration metadata, and the caller must own an existing undeleted chat/group.
CREATE OR REPLACE FUNCTION private.can_read_character_asset(
  p_bucket_id text,
  p_object_name text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT auth.uid() IS NOT NULL
    AND CASE p_bucket_id
      WHEN 'character-illustrations' THEN EXISTS (
        SELECT 1
        FROM public.character_illustrations AS ci
        WHERE ci.storage_path = p_object_name
          AND private.user_has_existing_character_session(ci.character_id)
      )
      WHEN 'character-avatar-videos' THEN EXISTS (
        SELECT 1
        FROM public.characters AS c
        WHERE c.avatar_video_path = p_object_name
          AND private.user_has_existing_character_session(c.id)
      )
      ELSE false
    END;
$function$;

REVOKE ALL ON FUNCTION private.can_read_character_asset(text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_read_character_asset(text, text)
  TO authenticated;

-- Existing public/author policies remain. These additional SELECT policies are
-- authenticated-only and do not allow upload, update, or delete.
DROP POLICY IF EXISTS "Existing session owners can read character illustration metadata"
  ON public.character_illustrations;
CREATE POLICY "Existing session owners can read character illustration metadata"
  ON public.character_illustrations
  FOR SELECT TO authenticated
  USING (private.user_has_existing_character_session(character_id));

DROP POLICY IF EXISTS "Existing session owners can read archived character assets"
  ON storage.objects;
CREATE POLICY "Existing session owners can read archived character assets"
  ON storage.objects
  FOR SELECT TO authenticated
  USING (private.can_read_character_asset(bucket_id, name));

-- 5) Service-only account archive helper.
-- service_role currently lacks USAGE on private; grant it before invoking this helper.
GRANT USAGE ON SCHEMA private TO service_role;

-- Call from the final prepare_account_deletion() transaction only after the
-- request is due and account writes are frozen, but BEFORE deleting auth.users.
-- It preserves all characters (including private/unpublished) and all child rows.
CREATE OR REPLACE FUNCTION private.archive_account_characters(
  p_user_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_nickname text;
  v_handle text;
  v_archived_at timestamptz := pg_catalog.statement_timestamp();
  v_character_count integer := 0;
BEGIN
  -- Trust the signed JWT role claim; auth.role() is deprecated by Supabase.
  IF (auth.jwt() ->> 'role') IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'target_user_required' USING ERRCODE = '22023';
  END IF;

  SELECT p.nickname, p.handle
    INTO v_nickname, v_handle
  FROM public.profiles AS p
  WHERE p.id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile_not_found_before_character_archive' USING ERRCODE = 'P0002';
  END IF;

  -- Lock all characters first; no publication-state filter by design.
  PERFORM 1
  FROM public.characters AS c
  WHERE c.author_id = p_user_id
  FOR UPDATE;

  -- Preserve creator attribution in every existing single-chat snapshot.
  WITH owned AS (
    SELECT c.id,
      COALESCE(NULLIF(c.creator_display_name, ''),
               NULLIF(v_nickname, ''),
               NULLIF(v_handle, ''),
               '已停用作者') AS creator_name,
      COALESCE(NULLIF(c.creator_handle_snapshot, ''),
               NULLIF(v_handle, '')) AS creator_handle
    FROM public.characters AS c
    WHERE c.author_id = p_user_id
  )
  UPDATE public.chat_sessions AS s
  SET character_snapshot =
      COALESCE(s.character_snapshot, '{}'::jsonb) ||
      jsonb_build_object(
        'authorId', NULL,
        'creatorDisplayName', owned.creator_name,
        'creatorHandleSnapshot', owned.creator_handle,
        'visibility', 'private',
        'accountArchivedAt', v_archived_at
      ),
      updated_at = v_archived_at
  FROM owned
  WHERE s.character_id = owned.id;

  -- Preserve creator attribution in group member snapshots.
  WITH owned AS (
    SELECT c.id,
      COALESCE(NULLIF(c.creator_display_name, ''),
               NULLIF(v_nickname, ''),
               NULLIF(v_handle, ''),
               '已停用作者') AS creator_name,
      COALESCE(NULLIF(c.creator_handle_snapshot, ''),
               NULLIF(v_handle, '')) AS creator_handle
    FROM public.characters AS c
    WHERE c.author_id = p_user_id
  )
  UPDATE public.chat_group_members AS gm
  SET character_snapshot =
      COALESCE(gm.character_snapshot, '{}'::jsonb) ||
      jsonb_build_object(
        'authorId', NULL,
        'creatorDisplayName', owned.creator_name,
        'creatorHandleSnapshot', owned.creator_handle,
        'visibility', 'private',
        'accountArchivedAt', v_archived_at
      )
  FROM owned
  WHERE gm.character_id = owned.id;

  -- Preserve creator attribution in group speaker snapshots.
  WITH owned AS (
    SELECT c.id,
      COALESCE(NULLIF(c.creator_display_name, ''),
               NULLIF(v_nickname, ''),
               NULLIF(v_handle, ''),
               '已停用作者') AS creator_name,
      COALESCE(NULLIF(c.creator_handle_snapshot, ''),
               NULLIF(v_handle, '')) AS creator_handle
    FROM public.characters AS c
    WHERE c.author_id = p_user_id
  )
  UPDATE public.chat_group_messages AS gm
  SET speaker_snapshot =
      COALESCE(gm.speaker_snapshot, '{}'::jsonb) ||
      jsonb_build_object(
        'authorId', NULL,
        'creatorDisplayName', owned.creator_name,
        'creatorHandleSnapshot', owned.creator_handle,
        'visibility', 'private',
        'accountArchivedAt', v_archived_at
      )
  FROM owned
  WHERE gm.character_id = owned.id
    AND gm.speaker_type = 'character';

  -- Detach author IDs from character-owned children before profile/Auth deletion.
  UPDATE public.character_private_info
  SET author_id = NULL
  WHERE author_id = p_user_id;

  UPDATE public.character_illustrations
  SET author_id = NULL
  WHERE author_id = p_user_id;

  UPDATE public.character_schedule_descriptions
  SET author_id = NULL
  WHERE author_id = p_user_id;

  -- Cancel pending cleanup queue records only. Never delete Storage objects here.
  DELETE FROM public.character_illustration_cleanup_jobs
  WHERE author_id = p_user_id;

  -- Archive every character row and detach its active owner. Do not set deleted_at:
  -- this is account archival, not character-content deletion.
  UPDATE public.characters AS c
  SET creator_display_name =
        COALESCE(NULLIF(c.creator_display_name, ''),
                 NULLIF(v_nickname, ''),
                 NULLIF(v_handle, ''),
                 '已停用作者'),
      creator_handle_snapshot =
        COALESCE(NULLIF(c.creator_handle_snapshot, ''),
                 NULLIF(v_handle, '')),
      visibility = 'private',
      account_archived_at = COALESCE(c.account_archived_at, v_archived_at),
      author_id = NULL
  WHERE c.author_id = p_user_id;

  GET DIAGNOSTICS v_character_count = ROW_COUNT;
  RETURN v_character_count;
END;
$function$;

REVOKE ALL ON FUNCTION private.archive_account_characters(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.archive_account_characters(uuid)
  TO service_role;

-- 6) Required follow-up integration (not included here):
-- Live test-DB review on 2026-11-02 confirmed prepare_account_deletion(uuid)
-- currently does NOT call this helper. It archives billing evidence, then removes
-- the account's own legacy conversations; Auth/profile deletion can still cascade
-- through characters unless this helper is integrated first.
--
-- Add the following call inside the final prepare_account_deletion(p_user_id)
-- function, immediately after locking/validating the due account_deletion_requests
-- row and before the existing-batch lookup (including the early "deleting" retry
-- return). This placement is deliberate: the helper is idempotent, and every retry
-- must detach character ownership before any path can continue toward Auth deletion.
--
--   PERFORM private.archive_account_characters(p_user_id);
--
-- The call must execute in the SAME PostgreSQL transaction as the rest of
-- prepare_account_deletion. If later archive verification or cleanup fails, all
-- character detachment/snapshot changes must roll back with the transaction.
-- Do not put this call only in the worker's separate archive callback.
--
-- - Add account_archived_at IS NULL to every new-session gate:
--   character_can_start_chat, can_open_encounter_session, create_chat_group,
--   encounter-session, story-session, and any direct session INSERT/RPC.
-- - Update frontend snapshot sync so explicit canonical authorId:null is preserved
--   (do not use canonical.authorId || oldSnapshot.authorId).
-- - Render creatorDisplayName/creatorHandleSnapshot as plain text when authorId is null.
-- - Keep existing chat-turn / encounter-turn paths free of current public-eligibility checks.
-- - Re-check grants, function owner, private schema usage, and all RLS policies.
-- - Test on disposable local DB before any hosted migration is considered.
