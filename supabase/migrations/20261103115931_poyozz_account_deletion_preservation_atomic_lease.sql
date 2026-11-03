-- Generated migration using Supabase CLI v2.84.2:
-- 20261103115931_poyozz_account_deletion_preservation_atomic_lease.sql
-- Fresh incremental migration; do not edit or replay historical migrations.
-- Prerequisites already present in the test-project ledger:
--   20261103040547_poyozz_chat_deletion_privilege_hardening.sql
--   20261103090100_account_is_active_auth_user_existence_guard.sql
-- Apply only after the disposable current-state replay and security checks pass.

\n-- ============================================================================\n-- 1. Preserve authored characters, detach ownership, and archive account data\n-- ============================================================================\n\n-- 1) Durable, non-clickable creator attribution and explicit account archive marker.
ALTER TABLE public.characters
  ADD COLUMN IF NOT EXISTS creator_display_name text,
  ADD COLUMN IF NOT EXISTS account_archived_at timestamptz;

COMMENT ON COLUMN public.characters.creator_display_name IS
  'Plain-text historical creator attribution; not a profile link.';
-- Creator attribution is stored as plain text only; never as a profile link.
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
  -- Existing-session access requires a live, active account. Pair this with
  -- account_is_active()'s auth.users existence guard so an unexpired JWT from
  -- a deleted account cannot continue reading retained character assets.
  SELECT auth.uid() IS NOT NULL
    AND public.account_is_active() IS TRUE
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

-- Existing client-side illustration cleanup can already have a job in memory
-- when account archival detaches author_id and removes pending queue rows. The
-- old direct metadata SELECT filtered by author_id then falsely saw no reference
-- and could remove a still-live asset. This caller-bound RPC is fail-closed:
-- inactive/deleted/revoked sessions and any remaining reference all return false.
CREATE OR REPLACE FUNCTION public.can_process_character_illustration_cleanup(
  p_job_id uuid,
  p_user_id uuid,
  p_storage_path text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_session_id uuid;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'not_allowed_to_process_character_asset_cleanup'
      USING ERRCODE = '42501';
  END IF;

  IF NOT public.account_is_active() THEN
    RETURN false;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.character_illustration_cleanup_jobs AS j
    WHERE j.id = p_job_id
      AND j.author_id = p_user_id
      AND j.storage_path = p_storage_path
  ) THEN
    RETURN false;
  END IF;

  v_session_id := NULLIF(auth.jwt() ->> 'session_id', '')::uuid;
  IF v_session_id IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM auth.sessions AS s
       WHERE s.id = v_session_id AND s.user_id = p_user_id
     )
     OR NOT EXISTS (
       SELECT 1 FROM auth.users AS u
       WHERE u.id = p_user_id
     ) THEN
    RETURN false;
  END IF;

  IF p_storage_path IS NULL
     OR p_storage_path !~ (
       '^' || p_user_id::text ||
       '/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' ||
       '/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$'
     ) THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.character_illustrations AS ci
    WHERE ci.storage_path = p_storage_path
  ) OR EXISTS (
    SELECT 1 FROM public.characters AS c
    WHERE c.avatar_video_path = p_storage_path
  ) THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.can_process_character_illustration_cleanup(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_process_character_illustration_cleanup(uuid, uuid, text)
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

-- 5) Explicitly exclude account-archived characters from caller-side new-session
-- eligibility helpers as well as the INSERT triggers below.
CREATE OR REPLACE FUNCTION public.character_can_start_chat(p_character_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.characters AS c
    WHERE c.id = p_character_id
      AND c.account_archived_at IS NULL
      AND c.deleted_at IS NULL
      AND (
        c.author_id = (SELECT auth.uid())
        OR (c.visibility = 'public' AND c.review_status = 'approved')
      )
  );
$function$;

CREATE OR REPLACE FUNCTION public.can_open_encounter_session(p_character_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.characters AS c
    WHERE c.id = p_character_id
      AND c.account_archived_at IS NULL
      AND c.visibility = 'public'
      AND c.deleted_at IS NULL
      AND c.review_status = 'approved'
      AND c.rights_confirmed IS TRUE
      AND (
        c.is_nsfw IS NOT TRUE
        OR (
          auth.uid() IS NOT NULL
          AND private.current_user_is_adult()
        )
      )
  );
$function$;

-- City/map schedule discovery must also hide account-archived characters,
-- while public character discovery itself continues to return public works.
CREATE OR REPLACE FUNCTION public.get_encounter_character_schedule(p_character_id uuid)
RETURNS TABLE(
  weekday smallint,
  day_type text,
  start_time time without time zone,
  end_time time without time zone,
  location_key text,
  activity text,
  priority smallint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT
    s.weekday, s.day_type, s.start_time, s.end_time,
    s.location_key, s.activity, s.priority
  FROM public.characters AS c
  JOIN public.character_schedules AS s ON s.character_id = c.id
  WHERE c.id = p_character_id
    AND c.account_archived_at IS NULL
    AND c.visibility = 'public'
    AND c.deleted_at IS NULL
    AND c.review_status = 'approved'
    AND c.rights_confirmed IS TRUE
    AND s.is_active IS TRUE
    AND (
      c.is_nsfw IS NOT TRUE
      OR (
        (SELECT auth.uid()) IS NOT NULL
        AND private.current_user_is_adult()
      )
    )
  ORDER BY s.priority DESC, s.weekday NULLS FIRST, s.start_time;
$function$;

-- CREATE OR REPLACE preserves the currently audited function ownership and
-- EXECUTE ACLs; verify both again after local replay.

-- 6) Service-only account archive helper.
-- The helper is called internally by the SECURITY DEFINER prepare RPC; do not
-- broaden schema USAGE on the private schema just for this internal call.

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

  SELECT p.nickname
    INTO v_nickname
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

  -- Lock child rows whose data is retained but not otherwise updated below.
  -- This serializes in-flight owner writes against the archival transaction;
  -- after commit, the parent author_id is NULL and the owner RLS predicates fail.
  PERFORM 1
  FROM public.character_schedules AS cs
  JOIN public.characters AS c ON c.id = cs.character_id
  WHERE c.author_id = p_user_id
  FOR UPDATE OF cs;

  PERFORM 1
  FROM public.character_stories AS st
  JOIN public.characters AS c ON c.id = st.character_id
  WHERE c.author_id = p_user_id
  FOR UPDATE OF st;

  -- Preserve creator attribution in every existing single-chat snapshot.
  WITH owned AS (
    SELECT c.id,
      COALESCE(NULLIF(c.creator_display_name, ''),
               NULLIF(v_nickname, ''),
               '原作者') AS creator_name,
      c.visibility AS current_visibility
    FROM public.characters AS c
    WHERE c.author_id = p_user_id
  )
  UPDATE public.chat_sessions AS s
  SET character_snapshot =
      COALESCE(s.character_snapshot, '{}'::jsonb) ||
      jsonb_build_object(
        'authorId', NULL,
        'creatorDisplayName', owned.creator_name,
        'creatorProfileAvailable', false,
        'characterStatus', 'offline',
        'isOnline', false,
        'visibility', owned.current_visibility,
        'accountArchivedAt', v_archived_at
      ),
      updated_at = v_archived_at
  FROM owned
  WHERE s.character_id = owned.id
    -- The deleting account's own sessions are removed by the later Auth FK
    -- cascade. They were already snapshotted above for aggregate character
    -- counts, so do not UPDATE them while account deletion is pending: the
    -- pending-account guard intentionally rejects writes to those sessions.
    -- Only other players' retained sessions need the offline/creator snapshot.
    AND s.user_id <> p_user_id;

  -- Preserve creator attribution in group member snapshots.
  WITH owned AS (
    SELECT c.id,
      COALESCE(NULLIF(c.creator_display_name, ''),
               NULLIF(v_nickname, ''),
               '原作者') AS creator_name,
      c.visibility AS current_visibility
    FROM public.characters AS c
    WHERE c.author_id = p_user_id
  )
  UPDATE public.chat_group_members AS gm
  SET character_snapshot =
      COALESCE(gm.character_snapshot, '{}'::jsonb) ||
      jsonb_build_object(
        'authorId', NULL,
        'creatorDisplayName', owned.creator_name,
        'creatorProfileAvailable', false,
        'characterStatus', 'offline',
        'isOnline', false,
        'visibility', owned.current_visibility,
        'accountArchivedAt', v_archived_at
      )
  FROM owned
  WHERE gm.character_id = owned.id;

  -- Preserve creator attribution in group speaker snapshots.
  WITH owned AS (
    SELECT c.id,
      COALESCE(NULLIF(c.creator_display_name, ''),
               NULLIF(v_nickname, ''),
               '原作者') AS creator_name,
      c.visibility AS current_visibility
    FROM public.characters AS c
    WHERE c.author_id = p_user_id
  )
  UPDATE public.chat_group_messages AS gm
  SET speaker_snapshot =
      COALESCE(gm.speaker_snapshot, '{}'::jsonb) ||
      jsonb_build_object(
        'authorId', NULL,
        'creatorDisplayName', owned.creator_name,
        'creatorProfileAvailable', false,
        'characterStatus', 'offline',
        'isOnline', false,
        'visibility', owned.current_visibility,
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
                   '原作者'),
      -- Preserve the existing public/private visibility and review state.
      -- Account deletion marks the character offline; it does not delist the work.
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

-- 7) Transactional integration with the live prepare_account_deletion(uuid).
-- The complete replacement function, copied from the current test-DB definition
-- and amended with safe retry handling, lives in:
--   supabase/drafts/prepare-account-deletion-character-preservation-integration.sql
--
-- It deliberately does NOT call the helper before looking up the existing batch:
-- a retry after Auth deletion must not require the now-deleted profile row.
-- Instead it:
--   - returns immediately for an already-deleting batch, unless legacy owned
--     character rows still exist (then it archives those rows before returning);
--   - calls the helper for existing archived/archiving batches; and
--   - calls the helper for a new batch before any irreversible cleanup.
-- All helper calls execute inside the same prepare_account_deletion transaction.
-- The worker's deleting-recovery branch then performs only Auth/finalize steps.
--
-- Do not move either SQL file into active migrations until schema provenance,
-- disposable PostgreSQL replay, RLS/Storage tests and end-to-end deletion tests pass.\n\n-- ============================================================================\n-- 2. Reject new entries for account-archived characters\n-- ============================================================================\n\n-- Edge Functions already perform caller-JWT eligibility checks, but trusted
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
-- 7. A failure in any parent/child insert transaction rolls back all rows.\n\n-- ============================================================================\n-- 3. Freeze author-managed child writes while account deletion is pending\n-- ============================================================================\n\n-- Existing owner policies remain the permissive ownership/visibility checks.
-- These additional RESTRICTIVE policies are AND gates for authenticated users:
-- a pending-deletion account cannot read or mutate these owner-managed rows.
-- Public/anon reads are not changed because these policies target authenticated.
--
-- Pair with account-is-active-auth-user-existence-guard.sql so stale JWTs for
-- deleted Auth users also fail account_is_active().

DO $policy$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'character_private_info'
      AND c.relkind = 'r'
  ) THEN
    RAISE EXCEPTION 'required table public.character_private_info is missing';
  END IF;
END;
$policy$;

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_private_info;
CREATE POLICY account_must_be_active
  ON public.character_private_info
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_schedules;
CREATE POLICY account_must_be_active
  ON public.character_schedules
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_schedule_descriptions;
CREATE POLICY account_must_be_active
  ON public.character_schedule_descriptions
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

DROP POLICY IF EXISTS account_must_be_active
  ON public.character_illustrations;
CREATE POLICY account_must_be_active
  ON public.character_illustrations
  AS RESTRICTIVE
  FOR ALL
  TO authenticated
  USING (public.account_is_active())
  WITH CHECK (public.account_is_active());

-- No policy is added to character_comments or character_comment_likes here:
-- those are player-authored social records, not author-owned character settings.
-- Their deletion/anonymization policy is separate from character retention.\n\n-- ============================================================================\n-- 4. Integrate character preservation and chat-memory photo retention into prepare_account_deletion\n-- ============================================================================\n\n--
-- Retry safety:
--   1. An already-deleting batch returns without requiring the profile row.
--   2. If legacy deleting batches still have author-owned characters, archive them
--      first (only when such rows exist); this is safe even after Auth deletion.
--   3. Existing archived/archiving batch and new-batch paths call the helper before
--      any irreversible cleanup. Both calls are in this same function transaction.
--
-- This is a complete replacement of the current live function definition, not
-- a partial snippet. Re-diff against pg_get_functiondef() immediately before use.

-- Queue account-owned chat-memory photo paths only when the irreversible account
-- deletion prepare step begins (after the environment-specific account grace period).
-- Photos retain their own fixed 30-day clock from requested_at. A cancellation before
-- prepare creates no photo cleanup work. Queue rows survive Auth cascades.
CREATE OR REPLACE FUNCTION private.enqueue_account_chat_memory_photo_cleanup(
  p_user_id uuid,
  p_requested_at timestamptz,
  p_scheduled_for timestamptz
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_photo record;
  v_locked_photo public.chat_memory_photos%ROWTYPE;
  v_parent_owner uuid;
  v_parent_deleted_at timestamptz;
  v_resource_type text;
  v_resource_id uuid;
  v_deleted_at timestamptz;
  v_job_id uuid;
  v_job public.chat_deletion_jobs%ROWTYPE;
  v_storage_job public.chat_storage_deletion_jobs%ROWTYPE;
  v_queued integer := 0;
BEGIN
  IF p_user_id IS NULL OR p_requested_at IS NULL OR p_scheduled_for IS NULL
     OR p_scheduled_for <= p_requested_at THEN
    RAISE EXCEPTION 'account_chat_photo_retention_window_mismatch';
  END IF;

  FOR v_photo IN
    SELECT p.id, p.owner_id, p.chat_type, p.session_id, p.group_id, p.storage_path
    FROM public.chat_memory_photos AS p
    WHERE p.owner_id = p_user_id
    -- Match snapshot_account_chat_character_history(): lock all solo parents
    -- first (stable ID order), then all group parents, preventing inverse-order
    -- deadlocks when account preparation and other lifecycle writers overlap.
    ORDER BY CASE WHEN p.chat_type = 'single' THEN 0 ELSE 1 END,
      COALESCE(p.session_id, p.group_id), p.id
  LOOP
    IF v_photo.storage_path !~ ('^' || p_user_id::text || '/')
       OR char_length(v_photo.storage_path) > 1024 THEN
      RAISE EXCEPTION 'account_chat_photo_storage_path_invalid';
    END IF;

    IF v_photo.chat_type = 'single' THEN
      v_resource_type := 'single_session';
      v_resource_id := v_photo.session_id;
      SELECT s.user_id, s.deleted_at
        INTO v_parent_owner, v_parent_deleted_at
      FROM public.chat_sessions AS s
      WHERE s.id = v_resource_id
      FOR UPDATE;
    ELSIF v_photo.chat_type = 'group' THEN
      v_resource_type := 'group';
      v_resource_id := v_photo.group_id;
      SELECT g.owner_id, g.deleted_at
        INTO v_parent_owner, v_parent_deleted_at
      FROM public.chat_groups AS g
      WHERE g.id = v_resource_id
      FOR UPDATE;
    ELSE
      RAISE EXCEPTION 'account_chat_photo_type_invalid';
    END IF;

    IF NOT FOUND OR v_parent_owner IS DISTINCT FROM p_user_id THEN
      RAISE EXCEPTION 'account_chat_photo_parent_owner_mismatch';
    END IF;

    -- Preserve the common parent-first lock order used by chat writers. The
    -- initial photo scan is unlocked; re-lock and verify the exact row only
    -- after its parent has been locked to avoid delete/photo-write deadlocks.
    SELECT p.* INTO v_locked_photo
    FROM public.chat_memory_photos AS p
    WHERE p.id = v_photo.id
    FOR UPDATE;

    IF NOT FOUND
       OR v_locked_photo.owner_id IS DISTINCT FROM p_user_id
       OR v_locked_photo.chat_type IS DISTINCT FROM v_photo.chat_type
       OR v_locked_photo.session_id IS DISTINCT FROM v_photo.session_id
       OR v_locked_photo.group_id IS DISTINCT FROM v_photo.group_id
       OR v_locked_photo.storage_path IS DISTINCT FROM v_photo.storage_path THEN
      RAISE EXCEPTION 'account_chat_photo_changed_during_queueing';
    END IF;

    -- Existing soft-deleted chats keep their original deletion clock. Active
    -- account-owned chats receive the account request timestamp. Photo retention
    -- is independently fixed at 30 days even when a test environment uses a shorter
    -- account grace period; cancellation before prepare creates no cleanup jobs.
    v_deleted_at := COALESCE(v_parent_deleted_at, p_requested_at);

    -- An account-prepare photo job can outlive a failed/interrupted Auth cascade.
    -- Mark the owned parent with the exact same retention timestamp so the normal
    -- day-30 purge RPC can still validate and purge it if the parent remains present.
    -- The account worker uses a service-role JWT without an end-user sub claim; this
    -- is an internal lifecycle transition, not a user-authored chat update.
    IF v_resource_type = 'single_session' THEN
      UPDATE public.chat_sessions AS s
      SET deleted_at = COALESCE(s.deleted_at, v_deleted_at),
          updated_at = pg_catalog.statement_timestamp()
      WHERE s.id = v_resource_id
        AND s.user_id = p_user_id
        AND s.deleted_at IS NOT DISTINCT FROM v_parent_deleted_at;
    ELSE
      UPDATE public.chat_groups AS g
      SET deleted_at = COALESCE(g.deleted_at, v_deleted_at),
          updated_at = pg_catalog.statement_timestamp()
      WHERE g.id = v_resource_id
        AND g.owner_id = p_user_id
        AND g.deleted_at IS NOT DISTINCT FROM v_parent_deleted_at;
    END IF;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'account_chat_photo_parent_changed_during_queueing';
    END IF;

    INSERT INTO public.chat_deletion_jobs (
      resource_type, resource_id, owner_id, deleted_at, purge_after
    ) VALUES (
      v_resource_type, v_resource_id, p_user_id, v_deleted_at,
      v_deleted_at + interval '30 days'
    )
    ON CONFLICT (resource_type, resource_id) DO NOTHING;

    SELECT j.* INTO v_job
    FROM public.chat_deletion_jobs AS j
    WHERE j.resource_type = v_resource_type
      AND j.resource_id = v_resource_id
    FOR UPDATE;

    IF NOT FOUND OR v_job.owner_id IS DISTINCT FROM p_user_id
       OR v_job.deleted_at IS DISTINCT FROM v_deleted_at
       OR v_job.purge_after IS DISTINCT FROM v_deleted_at + interval '30 days' THEN
      RAISE EXCEPTION 'account_chat_photo_deletion_job_conflict';
    END IF;

    INSERT INTO public.chat_storage_deletion_jobs (
      deletion_job_id, bucket_id, object_path, resource_type, resource_id, owner_id
    ) VALUES (
      v_job.id, 'personax-memory-photos', v_photo.storage_path,
      v_resource_type, v_resource_id, p_user_id
    )
    ON CONFLICT (bucket_id, object_path) DO NOTHING;

    SELECT sj.* INTO v_storage_job
    FROM public.chat_storage_deletion_jobs AS sj
    WHERE sj.bucket_id = 'personax-memory-photos'
      AND sj.object_path = v_photo.storage_path
    FOR UPDATE;

    IF NOT FOUND OR v_storage_job.deletion_job_id IS DISTINCT FROM v_job.id
       OR v_storage_job.resource_type IS DISTINCT FROM v_resource_type
       OR v_storage_job.resource_id IS DISTINCT FROM v_resource_id
       OR v_storage_job.owner_id IS DISTINCT FROM p_user_id THEN
      RAISE EXCEPTION 'account_chat_photo_storage_job_conflict';
    END IF;

    v_queued := v_queued + 1;
  END LOOP;

  RETURN v_queued;
END;
$function$;

REVOKE ALL ON FUNCTION private.enqueue_account_chat_memory_photo_cleanup(uuid, timestamptz, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.enqueue_account_chat_memory_photo_cleanup(uuid, timestamptz, timestamptz)
  TO postgres;

-- Group chat charges are independent financial/idempotency evidence. The
-- group parent and auth user both cascade to these rows, so archive them first.
-- Group turn request_content is transcript content: retain only the minimal
-- idempotency metadata, never the player's message text.
ALTER TABLE public.account_deletion_archive_items
  DROP CONSTRAINT IF EXISTS account_deletion_archive_items_source_table_check;
ALTER TABLE public.account_deletion_archive_items
  ADD CONSTRAINT account_deletion_archive_items_source_table_check
  CHECK (source_table IN (
    'ai_generation_records',
    'wallet_transactions',
    'chat_turn_charges',
    'chat_turn_events',
    'chat_group_turn_charges',
    'chat_group_turns'
  ));

CREATE OR REPLACE FUNCTION public.prepare_account_deletion(p_user_id uuid)
 RETURNS TABLE(batch_id uuid, target_user_id uuid, batch_status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_requested_at timestamptz;
  v_scheduled_for timestamptz;
  v_batch_id uuid;
  v_status text;
  v_ai_source bigint;
  v_ai_archived bigint;
  v_wallet_source bigint;
  v_wallet_archived bigint;
  v_charge_source bigint;
  v_charge_archived bigint;
  v_event_source bigint;
  v_event_archived bigint;
  v_group_charge_source bigint;
  v_group_charge_archived bigint;
  v_group_turn_source bigint;
  v_group_turn_archived bigint;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION '目標帳號不可為空';
  END IF;

  SELECT r.requested_at, r.scheduled_for
    INTO v_requested_at, v_scheduled_for
  FROM public.account_deletion_requests AS r
  WHERE r.user_id = p_user_id
    AND r.scheduled_for <= pg_catalog.statement_timestamp()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到此帳號已到期的刪除申請';
  END IF;

  -- Enqueue only after the recovery deadline has elapsed and this exact
  -- request row is locked. A cancellation that wins before this point leaves
  -- no photo cleanup jobs behind; queue retention ends at scheduled_for.
  PERFORM private.enqueue_account_chat_memory_photo_cleanup(
    p_user_id, v_requested_at, v_scheduled_for
  );

  -- Account deletion bypasses chat soft-delete RPCs; preserve character-use
  -- tombstones and completed assistant-turn totals before Auth FK cascades.
  -- This is idempotent and shares this transaction with all later archive steps.
  PERFORM private.snapshot_account_chat_character_history(p_user_id);

  -- Lock/reuse this exact request's batch. Never create a second active batch.
  SELECT b.id, b.status
    INTO v_batch_id, v_status
  FROM public.account_deletion_archive_batches AS b
  WHERE b.target_user_id = p_user_id
    AND b.requested_at = v_requested_at
    AND b.scheduled_for = v_scheduled_for
    AND b.status NOT IN ('completed', 'cancelled')
  ORDER BY b.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND AND v_status = 'deleting' THEN
    -- New-code deleting batches already committed character archival atomically.
    -- Heal a legacy deleting batch only if owned character rows are still present;
    -- this also keeps a retry safe after the Auth profile has already disappeared.
    IF EXISTS (
      SELECT 1 FROM public.characters AS c
      WHERE c.author_id = p_user_id
    ) THEN
      PERFORM private.archive_account_characters(p_user_id);
    END IF;
    -- The status change and relational cleanup commit in one PostgreSQL transaction.
    -- Therefore a committed deleting batch means cleanup already completed; do not
    -- compare now-empty source tables with their preserved archive row counts.
    RETURN QUERY SELECT v_batch_id, p_user_id, 'deleting'::text;
    RETURN;
  ELSIF FOUND THEN
    -- The Auth profile still exists while this branch is active. Archive all of its
    -- characters in this same transaction before marking the batch deleting.
    PERFORM private.archive_account_characters(p_user_id);

    -- Backfill billing/audit snapshots for older batches created before these source
    -- tables were added to the archive. ON CONFLICT preserves any prior payload so the
    -- exact-payload checks below still fail closed on a conflicting existing snapshot.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_charges', c.turn_id::text, pg_catalog.to_jsonb(c)
    FROM public.chat_turn_charges AS c
    WHERE c.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_events', e.event_id::text, pg_catalog.to_jsonb(e)
    FROM public.chat_turn_events AS e
    WHERE e.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turn_charges', gc.id::text, pg_catalog.to_jsonb(gc)
    FROM public.chat_group_turn_charges AS gc
    WHERE gc.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    -- Exclude request_content and user_id: this preserves retry/idempotency
    -- metadata without retaining the group player's transcript text.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turns', gt.id::text,
      pg_catalog.jsonb_build_object(
        'id', gt.id,
        'group_id', gt.group_id,
        'request_key', gt.request_key,
        'status', gt.status,
        'created_at', gt.created_at,
        'completed_at', gt.completed_at
      )
    FROM public.chat_group_turns AS gt
    WHERE gt.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    -- A failed or interrupted archive can be retried only if every remaining source row
    -- is exactly represented in the existing archive. Any mismatch fails closed.
    SELECT count(*) INTO v_ai_source
    FROM public.ai_generation_records AS a WHERE a.user_id = p_user_id;
    SELECT count(*) INTO v_wallet_source
    FROM public.wallet_transactions AS w WHERE w.user_id = p_user_id;
    SELECT count(*) INTO v_ai_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'ai_generation_records';
    SELECT count(*) INTO v_wallet_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'wallet_transactions';
    SELECT count(*) INTO v_charge_source
    FROM public.chat_turn_charges AS c WHERE c.user_id = p_user_id;
    SELECT count(*) INTO v_charge_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_charges';
    SELECT count(*) INTO v_event_source
    FROM public.chat_turn_events AS e WHERE e.user_id = p_user_id;
    SELECT count(*) INTO v_event_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_events';
    SELECT count(*) INTO v_group_charge_source
    FROM public.chat_group_turn_charges AS gc WHERE gc.user_id = p_user_id;
    SELECT count(*) INTO v_group_charge_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turn_charges';
    SELECT count(*) INTO v_group_turn_source
    FROM public.chat_group_turns AS gt WHERE gt.user_id = p_user_id;
    SELECT count(*) INTO v_group_turn_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turns';

    IF v_ai_source <> v_ai_archived OR v_wallet_source <> v_wallet_archived
       OR v_charge_source <> v_charge_archived OR v_event_source <> v_event_archived
       OR v_group_charge_source <> v_group_charge_archived
       OR v_group_turn_source <> v_group_turn_archived
       OR EXISTS (
         SELECT 1 FROM public.ai_generation_records AS a
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'ai_generation_records'
          AND i.source_record_id = a.id::text
         WHERE a.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(a))
       )
       OR EXISTS (
         SELECT 1 FROM public.wallet_transactions AS w
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'wallet_transactions'
          AND i.source_record_id = w.id::text
         WHERE w.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(w))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_turn_charges AS c
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_turn_charges'
          AND i.source_record_id = c.turn_id::text
         WHERE c.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(c))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_turn_events AS e
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_turn_events'
          AND i.source_record_id = e.event_id::text
         WHERE e.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(e))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_group_turn_charges AS gc
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_group_turn_charges'
          AND i.source_record_id = gc.id::text
         WHERE gc.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(gc))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_group_turns AS gt
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_group_turns'
          AND i.source_record_id = gt.id::text
         WHERE gt.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.jsonb_build_object(
             'id', gt.id,
             'group_id', gt.group_id,
             'request_key', gt.request_key,
             'status', gt.status,
             'created_at', gt.created_at,
             'completed_at', gt.completed_at
           ))
       ) THEN
      RAISE EXCEPTION '既有封存批次與來源資料不一致，已停止刪除以避免資料遺失';
    END IF;

    UPDATE public.account_deletion_archive_batches AS b
    SET status = 'archived',
        attempt_count = b.attempt_count + 1,
        started_at = pg_catalog.statement_timestamp(),
        updated_at = pg_catalog.statement_timestamp(),
        last_error = NULL
    WHERE b.id = v_batch_id;
  ELSE
    -- No existing batch: preserve/detach every character before creating the archive
    -- batch. Any later failure rolls this change back with the same transaction.
    PERFORM private.archive_account_characters(p_user_id);

    SELECT a.batch_id INTO v_batch_id
    FROM public.archive_account_deletion_data(p_user_id) AS a
    LIMIT 1;

    -- Preserve billing/audit rows as well as the original AI and wallet archive payloads.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_charges', c.turn_id::text, pg_catalog.to_jsonb(c)
    FROM public.chat_turn_charges AS c
    WHERE c.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_events', e.event_id::text, pg_catalog.to_jsonb(e)
    FROM public.chat_turn_events AS e
    WHERE e.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turn_charges', gc.id::text, pg_catalog.to_jsonb(gc)
    FROM public.chat_group_turn_charges AS gc
    WHERE gc.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    -- Exclude request_content and user_id: this preserves retry/idempotency
    -- metadata without retaining the group player's transcript text.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turns', gt.id::text,
      pg_catalog.jsonb_build_object(
        'id', gt.id,
        'group_id', gt.group_id,
        'request_key', gt.request_key,
        'status', gt.status,
        'created_at', gt.created_at,
        'completed_at', gt.completed_at
      )
    FROM public.chat_group_turns AS gt
    WHERE gt.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    v_status := 'archived';
  END IF;

  -- Verify billing/audit archive rows too before any irreversible deletion.
  SELECT count(*) INTO v_charge_source
  FROM public.chat_turn_charges AS c WHERE c.user_id = p_user_id;
  SELECT count(*) INTO v_charge_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_charges';
  SELECT count(*) INTO v_event_source
  FROM public.chat_turn_events AS e WHERE e.user_id = p_user_id;
  SELECT count(*) INTO v_event_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_events';
  SELECT count(*) INTO v_group_charge_source
  FROM public.chat_group_turn_charges AS gc WHERE gc.user_id = p_user_id;
  SELECT count(*) INTO v_group_charge_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turn_charges';
  SELECT count(*) INTO v_group_turn_source
  FROM public.chat_group_turns AS gt WHERE gt.user_id = p_user_id;
  SELECT count(*) INTO v_group_turn_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turns';

  IF v_charge_source <> v_charge_archived OR v_event_source <> v_event_archived
     OR v_group_charge_source <> v_group_charge_archived
     OR v_group_turn_source <> v_group_turn_archived
     OR EXISTS (
       SELECT 1 FROM public.chat_turn_charges AS c
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_turn_charges'
        AND i.source_record_id = c.turn_id::text
       WHERE c.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(c))
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_turn_events AS e
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_turn_events'
        AND i.source_record_id = e.event_id::text
       WHERE e.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(e))
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_group_turn_charges AS gc
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_group_turn_charges'
        AND i.source_record_id = gc.id::text
       WHERE gc.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(gc))
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_group_turns AS gt
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_group_turns'
        AND i.source_record_id = gt.id::text
       WHERE gt.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.jsonb_build_object(
           'id', gt.id,
           'group_id', gt.group_id,
           'request_key', gt.request_key,
           'status', gt.status,
           'created_at', gt.created_at,
           'completed_at', gt.completed_at
         ))
     ) THEN
    RAISE EXCEPTION '聊天扣款／事件紀錄封存核對失敗，已停止刪除';
  END IF;

  -- Archive verified: mark the irreversible phase before deleting source rows.
  UPDATE public.account_deletion_archive_batches AS b
  SET status = 'deleting',
      attempt_count = CASE WHEN b.attempt_count = 0 THEN 1 ELSE b.attempt_count END,
      started_at = COALESCE(b.started_at, pg_catalog.statement_timestamp()),
      updated_at = pg_catalog.statement_timestamp(),
      last_error = NULL
  WHERE b.id = v_batch_id;

  -- Remove non-cascading references before chat/profile/Auth deletion.
  DELETE FROM public.ai_generation_records WHERE user_id = p_user_id;

  -- Delete version history only for messages owned by the account being deleted.
  -- If this user edited another player's message, preserve that player's version rows
  -- and anonymize the editor reference instead of deleting someone else's history.
  DELETE FROM public.chat_message_versions AS v
  WHERE v.message_id IN (
    SELECT m.id
    FROM public.chat_messages AS m
    JOIN public.chat_sessions AS s ON s.id = m.session_id
    WHERE s.user_id = p_user_id
  );

  UPDATE public.chat_message_versions AS v
  SET edited_by = NULL
  WHERE v.edited_by = p_user_id
    AND NOT EXISTS (
      SELECT 1
      FROM public.chat_messages AS m
      JOIN public.chat_sessions AS s ON s.id = m.session_id
      WHERE m.id = v.message_id
        AND s.user_id = p_user_id
    );

  -- user_message_id uses ON DELETE RESTRICT, so charges must be removed before messages.
  DELETE FROM public.chat_turn_charges WHERE user_id = p_user_id;

  DELETE FROM public.wallet_transactions WHERE user_id = p_user_id;

  -- Old conversation schema and role/chat data are owned by the profile; their declared
  -- CASCADE relationships remove stories, private info, conversations/messages and sessions.
  -- Explicitly remove conversations first so the cleanup is clear and retry-safe.
  DELETE FROM public.conversations WHERE user_id = p_user_id;

  RETURN QUERY SELECT v_batch_id, p_user_id, 'deleting'::text;
END;
$function$;\n\n-- ============================================================================\n-- 5. Atomic account-deletion worker lease and fencing protocol\n-- ============================================================================\n\n-- historical profiles/characters baseline is addressed by the approved current-state rollout.

CREATE TABLE IF NOT EXISTS public.account_deletion_work_leases (
  target_user_id uuid PRIMARY KEY,
  requested_at timestamptz NOT NULL,
  scheduled_for timestamptz NOT NULL,
  lease_token uuid NOT NULL,
  lease_generation bigint NOT NULL DEFAULT 0 CHECK (lease_generation >= 0),
  lease_expires_at timestamptz NOT NULL,
  lease_status text NOT NULL CHECK (lease_status IN ('claimed', 'completed', 'cancelled')),
  batch_id uuid,
  claimed_at timestamptz NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  last_error text
);

COMMENT ON TABLE public.account_deletion_work_leases IS
  'Durable service-only account deletion worker lease. Intentionally has no Auth/request FK so recovery survives profile/Auth cascades.';

ALTER TABLE public.account_deletion_work_leases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.account_deletion_work_leases FROM PUBLIC, anon, authenticated, service_role;

-- One invocation claims one account. Ten minutes is a provisional bounded lease;
-- keep the limit at one until local phase-duration telemetry supports a different value.
-- Renew is required immediately before every external Auth Admin call and finalization.
CREATE OR REPLACE FUNCTION public.claim_account_deletion_work_items(p_limit integer DEFAULT 1)
RETURNS TABLE(
  target_user_id uuid,
  batch_id uuid,
  scheduled_for timestamptz,
  work_status text,
  lease_token uuid,
  lease_generation bigint,
  lease_expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_request record;
  v_batch record;
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_id uuid;
  v_active_count integer;
  v_claimed integer := 0;
  v_now timestamptz := pg_catalog.statement_timestamp();
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'invalid_account_deletion_claim_limit' USING ERRCODE = '22023';
  END IF;

  -- Due requests: lock request first, then lease, then any archive batch.
  FOR v_request IN
    SELECT q.user_id, q.requested_at, q.scheduled_for
    FROM public.account_deletion_requests AS q
    WHERE q.scheduled_for <= v_now
      AND NOT EXISTS (
        SELECT 1
        FROM public.account_deletion_work_leases AS active_lease
        WHERE active_lease.target_user_id = q.user_id
          AND active_lease.lease_status = 'claimed'
          AND active_lease.lease_expires_at > v_now
      )
    ORDER BY q.scheduled_for, q.user_id
    FOR UPDATE SKIP LOCKED
  LOOP
    EXIT WHEN v_claimed >= p_limit;
    v_batch_id := NULL;
    SELECT pg_catalog.count(*)::integer
      INTO v_active_count
    FROM public.account_deletion_archive_batches AS b
    WHERE b.target_user_id = v_request.user_id
      AND b.requested_at = v_request.requested_at
      AND b.scheduled_for = v_request.scheduled_for
      AND b.status IN ('pending', 'archiving', 'archived', 'deleting');

    IF v_active_count > 1 THEN
      RAISE EXCEPTION 'duplicate_active_account_deletion_batches';
    END IF;

    -- Prefer a non-blocking lease lock before attempting first-row insertion.
    SELECT l.* INTO v_lease
    FROM public.account_deletion_work_leases AS l
    WHERE l.target_user_id = v_request.user_id
    FOR UPDATE SKIP LOCKED;

    IF NOT FOUND THEN
      IF EXISTS (
        SELECT 1 FROM public.account_deletion_work_leases AS existing_lease
        WHERE existing_lease.target_user_id = v_request.user_id
      ) THEN
        CONTINUE;
      END IF;

      INSERT INTO public.account_deletion_work_leases (
        target_user_id, requested_at, scheduled_for, lease_token,
        lease_generation, lease_expires_at, lease_status, batch_id
      ) VALUES (
        v_request.user_id, v_request.requested_at, v_request.scheduled_for,
        pg_catalog.gen_random_uuid(), 0, v_now,
        'cancelled', NULL
      )
      ON CONFLICT ON CONSTRAINT account_deletion_work_leases_pkey DO NOTHING;

      SELECT l.* INTO v_lease
      FROM public.account_deletion_work_leases AS l
      WHERE l.target_user_id = v_request.user_id
      FOR UPDATE SKIP LOCKED;

      IF NOT FOUND THEN
        CONTINUE;
      END IF;
    END IF;
    IF v_lease.lease_status = 'completed' AND v_active_count > 0 THEN
      RAISE EXCEPTION 'completed_account_deletion_lease_has_active_batch';
    END IF;

    IF v_lease.requested_at IS DISTINCT FROM v_request.requested_at
       OR v_lease.scheduled_for IS DISTINCT FROM v_request.scheduled_for THEN
      IF v_lease.lease_status <> 'cancelled' THEN
        RAISE EXCEPTION 'account_deletion_lease_request_identity_mismatch';
      END IF;
      UPDATE public.account_deletion_work_leases AS l
      SET requested_at = v_request.requested_at,
          scheduled_for = v_request.scheduled_for,
          lease_token = pg_catalog.gen_random_uuid(),
          lease_generation = l.lease_generation + 1,
          lease_expires_at = pg_catalog.clock_timestamp() + interval '10 minutes',
          lease_status = 'claimed',
          batch_id = v_batch_id,
          claimed_at = pg_catalog.clock_timestamp(),
          updated_at = pg_catalog.clock_timestamp(),
          attempt_count = 0,
          last_error = NULL
      WHERE l.target_user_id = v_request.user_id
      RETURNING l.* INTO v_lease;
    ELSE
      IF v_lease.lease_status = 'completed'
         OR (v_lease.lease_status = 'claimed' AND v_lease.lease_expires_at > v_now) THEN
        CONTINUE;
      END IF;
      UPDATE public.account_deletion_work_leases AS l
      SET lease_token = pg_catalog.gen_random_uuid(),
          lease_generation = l.lease_generation + 1,
          lease_expires_at = pg_catalog.clock_timestamp() + interval '10 minutes',
          lease_status = 'claimed',
          batch_id = COALESCE(v_batch_id, l.batch_id),
          claimed_at = pg_catalog.clock_timestamp(),
          updated_at = pg_catalog.clock_timestamp(),
          last_error = NULL
      WHERE l.target_user_id = v_request.user_id
      RETURNING l.* INTO v_lease;
    END IF;

    -- The request lock and lease lock are held before taking the batch lock.
    SELECT b.id INTO v_batch_id
    FROM public.account_deletion_archive_batches AS b
    WHERE b.target_user_id = v_request.user_id
      AND b.requested_at = v_request.requested_at
      AND b.scheduled_for = v_request.scheduled_for
      AND b.status NOT IN ('completed', 'cancelled')
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;

    UPDATE public.account_deletion_work_leases AS l
    SET batch_id = COALESCE(v_batch_id, l.batch_id),
        lease_expires_at = pg_catalog.clock_timestamp() + interval '10 minutes',
        updated_at = pg_catalog.clock_timestamp()
    WHERE l.target_user_id = v_request.user_id
      AND l.lease_token = v_lease.lease_token
      AND l.lease_generation = v_lease.lease_generation
    RETURNING l.* INTO v_lease;

    target_user_id := v_request.user_id;
    batch_id := v_batch_id;
    scheduled_for := v_request.scheduled_for;
    work_status := CASE WHEN v_batch_id IS NULL THEN 'due' ELSE 'archived' END;
    lease_token := v_lease.lease_token;
    lease_generation := v_lease.lease_generation;
    lease_expires_at := v_lease.lease_expires_at;
    RETURN NEXT;
    v_claimed := v_claimed + 1;
    EXIT WHEN v_claimed >= p_limit;
  END LOOP;

  -- Recover committed deleting batches whose request row was removed by prepare.
  -- The lease row is intentionally independent of Auth and request FKs.
  IF v_claimed < p_limit THEN
    FOR v_batch IN
      SELECT b.id, b.target_user_id, b.requested_at, b.scheduled_for
      FROM public.account_deletion_archive_batches AS b
      WHERE b.status = 'deleting'
        AND b.target_user_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.account_deletion_requests AS q
          WHERE q.user_id = b.target_user_id
            AND q.requested_at = b.requested_at
            AND q.scheduled_for = b.scheduled_for
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.account_deletion_work_leases AS active_lease
          WHERE active_lease.target_user_id = b.target_user_id
            AND active_lease.lease_status = 'claimed'
            AND active_lease.lease_expires_at > v_now
        )
      ORDER BY b.updated_at, b.id
    LOOP
      EXIT WHEN v_claimed >= p_limit;

      SELECT pg_catalog.count(*)::integer
        INTO v_active_count
      FROM public.account_deletion_archive_batches AS duplicate_batch
      WHERE duplicate_batch.target_user_id = v_batch.target_user_id
        AND duplicate_batch.requested_at = v_batch.requested_at
        AND duplicate_batch.scheduled_for = v_batch.scheduled_for
        AND duplicate_batch.status = 'deleting';
      IF v_active_count > 1 THEN
        RAISE EXCEPTION 'duplicate_deleting_account_batches';
      END IF;

      -- Recovery locks the lease first; an already locked row is skipped.
      SELECT l.* INTO v_lease
      FROM public.account_deletion_work_leases AS l
      WHERE l.target_user_id = v_batch.target_user_id
      FOR UPDATE SKIP LOCKED;

      IF NOT FOUND THEN
        IF EXISTS (
          SELECT 1 FROM public.account_deletion_work_leases AS existing_lease
          WHERE existing_lease.target_user_id = v_batch.target_user_id
        ) THEN
          CONTINUE;
        END IF;

        INSERT INTO public.account_deletion_work_leases (
          target_user_id, requested_at, scheduled_for, lease_token,
          lease_generation, lease_expires_at, lease_status, batch_id
        ) VALUES (
          v_batch.target_user_id, v_batch.requested_at, v_batch.scheduled_for,
          pg_catalog.gen_random_uuid(), 0, v_now,
          'cancelled', v_batch.id
        )
        ON CONFLICT ON CONSTRAINT account_deletion_work_leases_pkey DO NOTHING;

        SELECT l.* INTO v_lease
        FROM public.account_deletion_work_leases AS l
        WHERE l.target_user_id = v_batch.target_user_id
        FOR UPDATE SKIP LOCKED;

        IF NOT FOUND THEN
          CONTINUE;
        END IF;
      END IF;
      IF v_lease.requested_at IS DISTINCT FROM v_batch.requested_at
         OR v_lease.scheduled_for IS DISTINCT FROM v_batch.scheduled_for THEN
        RAISE EXCEPTION 'account_deletion_recovery_lease_identity_mismatch';
      END IF;
      IF v_lease.lease_status = 'completed' THEN
        RAISE EXCEPTION 'completed_account_deletion_lease_has_deleting_batch';
      END IF;
      IF v_lease.lease_status = 'claimed' AND v_lease.lease_expires_at > v_now THEN
        CONTINUE;
      END IF;

      -- Recovery lock order is lease -> batch because the request row no longer exists.
      PERFORM 1
      FROM public.account_deletion_archive_batches AS b
      WHERE b.id = v_batch.id
        AND b.status = 'deleting'
      FOR UPDATE SKIP LOCKED;
      IF NOT FOUND THEN
        CONTINUE;
      END IF;

      UPDATE public.account_deletion_work_leases AS l
      SET lease_token = pg_catalog.gen_random_uuid(),
          lease_generation = l.lease_generation + 1,
          lease_expires_at = pg_catalog.clock_timestamp() + interval '10 minutes',
          lease_status = 'claimed',
          batch_id = v_batch.id,
          claimed_at = pg_catalog.clock_timestamp(),
          updated_at = pg_catalog.clock_timestamp(),
          last_error = NULL
      WHERE l.target_user_id = v_batch.target_user_id
      RETURNING l.* INTO v_lease;

      target_user_id := v_batch.target_user_id;
      batch_id := v_batch.id;
      scheduled_for := v_batch.scheduled_for;
      work_status := 'deleting';
      lease_token := v_lease.lease_token;
      lease_generation := v_lease.lease_generation;
      lease_expires_at := v_lease.lease_expires_at;
      RETURN NEXT;
      v_claimed := v_claimed + 1;
    END LOOP;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.renew_account_deletion_lease(
  p_user_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  UPDATE public.account_deletion_work_leases AS l
  SET lease_expires_at = pg_catalog.clock_timestamp() + interval '10 minutes',
      updated_at = pg_catalog.statement_timestamp()
  WHERE l.target_user_id = p_user_id
    AND l.lease_token = p_lease_token
    AND l.lease_generation = p_lease_generation
    AND l.lease_status = 'claimed'
    AND l.lease_expires_at > pg_catalog.clock_timestamp();
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.prepare_account_deletion_leased(
  p_user_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint
)
RETURNS TABLE(batch_id uuid, target_user_id uuid, batch_status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_requested_at timestamptz;
  v_scheduled_for timestamptz;
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_id uuid;
  v_batch_status text;
BEGIN
  -- Canonical lock order: request -> lease -> batch.
  SELECT q.requested_at, q.scheduled_for
    INTO v_requested_at, v_scheduled_for
  FROM public.account_deletion_requests AS q
  WHERE q.user_id = p_user_id
    AND q.scheduled_for <= pg_catalog.statement_timestamp()
  FOR UPDATE;

  IF FOUND THEN
    SELECT l.* INTO v_lease
    FROM public.account_deletion_work_leases AS l
    WHERE l.target_user_id = p_user_id
    FOR UPDATE;
    IF NOT FOUND OR v_lease.requested_at IS DISTINCT FROM v_requested_at
       OR v_lease.scheduled_for IS DISTINCT FROM v_scheduled_for
       OR v_lease.lease_token IS DISTINCT FROM p_lease_token
       OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
       OR v_lease.lease_status <> 'claimed'
       OR v_lease.lease_expires_at <= pg_catalog.clock_timestamp() THEN
      RAISE EXCEPTION 'account_deletion_lease_lost' USING ERRCODE = '55000';
    END IF;

    SELECT b.id INTO v_batch_id
    FROM public.account_deletion_archive_batches AS b
    WHERE b.target_user_id = p_user_id
      AND b.requested_at = v_requested_at
      AND b.scheduled_for = v_scheduled_for
      AND b.status NOT IN ('completed', 'cancelled')
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;

    -- This existing SECURITY DEFINER routine performs the verified archive and
    -- relational prepare in one transaction. Its direct service_role EXECUTE is
    -- revoked below; only this fenced wrapper remains callable by the worker.
    RETURN QUERY
      SELECT p.batch_id, p.target_user_id, p.batch_status
      FROM public.prepare_account_deletion(p_user_id) AS p;
    UPDATE public.account_deletion_work_leases AS l
    SET batch_id = (SELECT b.id FROM public.account_deletion_archive_batches AS b
                    WHERE b.target_user_id = p_user_id
                      AND b.requested_at = v_requested_at
                      AND b.scheduled_for = v_scheduled_for
                    ORDER BY b.created_at DESC LIMIT 1),
        updated_at = pg_catalog.statement_timestamp()
    WHERE l.target_user_id = p_user_id
      AND l.lease_token = p_lease_token
      AND l.lease_generation = p_lease_generation;
    RETURN;
  END IF;

  -- Recovery after prepare committed and cascaded the request row.
  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND OR v_lease.lease_token IS DISTINCT FROM p_lease_token
     OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
     OR v_lease.lease_status <> 'claimed'
     OR v_lease.lease_expires_at <= pg_catalog.clock_timestamp()
     OR v_lease.batch_id IS NULL THEN
    RAISE EXCEPTION 'account_deletion_lease_lost' USING ERRCODE = '55000';
  END IF;

  SELECT b.id, b.status INTO v_batch_id, v_batch_status
  FROM public.account_deletion_archive_batches AS b
  WHERE b.id = v_lease.batch_id
    AND b.target_user_id = p_user_id
    AND b.requested_at = v_lease.requested_at
    AND b.scheduled_for = v_lease.scheduled_for
  FOR UPDATE;

  IF NOT FOUND OR v_batch_status NOT IN ('deleting', 'completed') THEN
    RAISE EXCEPTION 'account_deletion_recovery_batch_not_ready';
  END IF;
  RETURN QUERY SELECT v_batch_id, p_user_id, v_batch_status;
END;
$function$;

CREATE OR REPLACE FUNCTION public.finalize_account_deletion_leased(
  p_user_id uuid,
  p_batch_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_user uuid;
BEGIN
  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND OR v_lease.lease_token IS DISTINCT FROM p_lease_token
     OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
     OR v_lease.lease_status <> 'claimed'
     OR v_lease.lease_expires_at <= pg_catalog.clock_timestamp()
     OR v_lease.batch_id IS DISTINCT FROM p_batch_id THEN
    RAISE EXCEPTION 'account_deletion_lease_lost' USING ERRCODE = '55000';
  END IF;

  SELECT b.target_user_id INTO v_batch_user
  FROM public.account_deletion_archive_batches AS b
  WHERE b.id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND OR v_batch_user IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'account_deletion_batch_lease_mismatch';
  END IF;

  IF NOT public.finalize_account_deletion(p_batch_id) THEN
    RETURN false;
  END IF;

  UPDATE public.account_deletion_work_leases AS l
  SET lease_status = 'completed',
      lease_expires_at = pg_catalog.clock_timestamp(),
      updated_at = pg_catalog.statement_timestamp(),
      last_error = NULL
  WHERE l.target_user_id = p_user_id
    AND l.lease_token = p_lease_token
    AND l.lease_generation = p_lease_generation;
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_account_deletion_failure_leased(
  p_user_id uuid,
  p_batch_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_lease public.account_deletion_work_leases%ROWTYPE;
BEGIN
  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND OR v_lease.lease_token IS DISTINCT FROM p_lease_token
     OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
     OR v_lease.lease_status <> 'claimed'
     OR v_lease.lease_expires_at <= pg_catalog.clock_timestamp()
     OR v_lease.batch_id IS DISTINCT FROM p_batch_id THEN
    RETURN false;
  END IF;

  -- Lock and validate the associated batch before writing either failure record.
  IF p_batch_id IS NOT NULL THEN
    PERFORM 1
    FROM public.account_deletion_archive_batches AS b
    WHERE b.id = p_batch_id
      AND b.target_user_id = p_user_id
      AND b.status IN ('archived', 'deleting', 'failed')
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN false;
    END IF;
  END IF;

  UPDATE public.account_deletion_work_leases AS l
  SET attempt_count = l.attempt_count + 1,
      last_error = pg_catalog.left(
        coalesce(nullif(p_error_code, ''), 'worker_error'), 300
      ),
      updated_at = pg_catalog.statement_timestamp()
  WHERE l.target_user_id = p_user_id
    AND l.lease_token = p_lease_token
    AND l.lease_generation = p_lease_generation;

  IF p_batch_id IS NOT NULL THEN
    UPDATE public.account_deletion_archive_batches AS b
    SET last_error = pg_catalog.left(
          coalesce(nullif(p_error_code, ''), 'worker_error'), 300
        ),
        updated_at = pg_catalog.statement_timestamp(),
        attempt_count = b.attempt_count + 1
    WHERE b.id = p_batch_id
      AND b.target_user_id = p_user_id
      AND b.status IN ('archived', 'deleting', 'failed');
  END IF;
  RETURN true;
END;
$function$;

-- Cancellation serializes with claim using request -> lease -> batch lock order.
CREATE OR REPLACE FUNCTION public.cancel_account_deletion()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_requested_at timestamptz;
  v_scheduled_for timestamptz;
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION '請先登入';
  END IF;

  SELECT r.requested_at, r.scheduled_for
    INTO v_requested_at, v_scheduled_for
  FROM public.account_deletion_requests AS r
  WHERE r.user_id = v_user_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到待處理的刪除申請';
  END IF;

  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = v_user_id
  FOR UPDATE;

  IF FOUND AND v_lease.lease_status = 'claimed'
     AND (v_lease.lease_expires_at > pg_catalog.clock_timestamp() OR v_lease.batch_id IS NOT NULL) THEN
    RAISE EXCEPTION '刪除處理已由背景工作領取，無法取消';
  END IF;

  SELECT b.id INTO v_batch_id
  FROM public.account_deletion_archive_batches AS b
  WHERE b.target_user_id = v_user_id
    AND b.requested_at = v_requested_at
    AND b.scheduled_for = v_scheduled_for
  ORDER BY b.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    RAISE EXCEPTION '刪除處理已開始，無法透過此功能復原；請交由管理程序檢查';
  END IF;

  DELETE FROM public.account_deletion_requests AS r
  WHERE r.user_id = v_user_id
    AND r.requested_at = v_requested_at
    AND r.scheduled_for = v_scheduled_for;
  IF NOT FOUND THEN
    RAISE EXCEPTION '刪除申請狀態已變更，請重新查詢帳號狀態';
  END IF;

  IF v_lease.target_user_id IS NOT NULL THEN
    UPDATE public.account_deletion_work_leases AS l
    SET lease_status = 'cancelled',
        lease_expires_at = pg_catalog.clock_timestamp(),
        updated_at = pg_catalog.clock_timestamp(),
        last_error = NULL
    WHERE l.target_user_id = v_user_id
      AND l.requested_at = v_requested_at
      AND l.scheduled_for = v_scheduled_for;
  END IF;
END;
$function$;

-- Remove all un-fenced service-role entry points. The SECURITY DEFINER wrappers
-- above call the original routines as their owner (postgres) within one transaction.
REVOKE ALL ON FUNCTION public.get_account_deletion_work_items() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.archive_account_deletion_data(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.prepare_account_deletion(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finalize_account_deletion(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_account_deletion_failure(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.claim_account_deletion_work_items(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.renew_account_deletion_lease(uuid, uuid, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prepare_account_deletion_leased(uuid, uuid, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_account_deletion_leased(uuid, uuid, uuid, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_account_deletion_failure_leased(uuid, uuid, uuid, bigint, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.claim_account_deletion_work_items(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.renew_account_deletion_lease(uuid, uuid, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.prepare_account_deletion_leased(uuid, uuid, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_account_deletion_leased(uuid, uuid, uuid, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_account_deletion_failure_leased(uuid, uuid, uuid, bigint, text) TO service_role;

-- Keep the player-facing cancellation RPC authenticated-only.
REVOKE ALL ON FUNCTION public.cancel_account_deletion() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_account_deletion() TO authenticated;\n