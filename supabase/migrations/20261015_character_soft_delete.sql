-- PersonaX character soft-delete migration
-- Apply this file in the Supabase SQL Editor before deploying the matching frontend.

ALTER TABLE public.characters
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS deletion_reason text;

CREATE INDEX IF NOT EXISTS characters_active_public_idx
  ON public.characters (visibility, review_status, first_published_at DESC)
  WHERE deleted_at IS NULL;

-- Prevent a deleted character from being restored through a direct client update.
CREATE OR REPLACE FUNCTION public.prevent_character_soft_delete_restore()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $$
BEGIN
  IF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
    RAISE EXCEPTION 'A soft-deleted character cannot be restored; create a new character instead.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS characters_prevent_soft_delete_restore ON public.characters;
CREATE TRIGGER characters_prevent_soft_delete_restore
BEFORE UPDATE OF deleted_at ON public.characters
FOR EACH ROW
EXECUTE FUNCTION public.prevent_character_soft_delete_restore();

-- A restrictive SELECT policy composes with the existing visibility/approval policies.
-- Owners can still inspect their deleted row; everyone else cannot read it directly.
DROP POLICY IF EXISTS characters_hide_soft_deleted_from_non_owner ON public.characters;
CREATE POLICY characters_hide_soft_deleted_from_non_owner
ON public.characters
AS RESTRICTIVE
FOR SELECT
TO anon, authenticated
USING (deleted_at IS NULL OR author_id = (SELECT auth.uid()));

-- SECURITY DEFINER helper lets chat_sessions INSERT policy check the true character
-- state even when the caller cannot SELECT a private/deleted character.
CREATE OR REPLACE FUNCTION public.character_is_not_soft_deleted(p_character_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.characters c
    WHERE c.id = p_character_id
      AND c.deleted_at IS NULL
  );
$$;

REVOKE ALL ON FUNCTION public.character_is_not_soft_deleted(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.character_is_not_soft_deleted(uuid) TO authenticated;

DROP POLICY IF EXISTS chat_sessions_no_new_deleted_character ON public.chat_sessions;
CREATE POLICY chat_sessions_no_new_deleted_character
ON public.chat_sessions
AS RESTRICTIVE
FOR INSERT
TO authenticated
WITH CHECK (public.character_is_not_soft_deleted(character_id));

-- Synchronize per-player snapshots when a creator makes a character private or public.
-- This keeps old sessions informed of publication state without exposing character rows.
CREATE OR REPLACE FUNCTION public.sync_character_chat_snapshot(p_character_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_author_id uuid;
  v_visibility text;
  v_first_published_at timestamptz;
  v_deleted_at timestamptz;
  v_count integer := 0;
BEGIN
  SELECT c.author_id, c.visibility, c.first_published_at, c.deleted_at
    INTO v_author_id, v_visibility, v_first_published_at, v_deleted_at
  FROM public.characters c
  WHERE c.id = p_character_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Character not found.';
  END IF;
  IF v_author_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Not allowed to update this character snapshot.';
  END IF;

  UPDATE public.chat_sessions cs
  SET character_snapshot = COALESCE(cs.character_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', v_visibility,
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    ),
    updated_at = now()
  WHERE cs.character_id = p_character_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_character_chat_snapshot(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_character_chat_snapshot(uuid) TO authenticated;

-- Atomically soft-delete the character and mark all player snapshots as retired.
-- The role/story/chat rows are retained; only public discoverability is removed.
CREATE OR REPLACE FUNCTION public.soft_delete_character(p_character_id uuid)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_author_id uuid;
  v_first_published_at timestamptz;
  v_deleted_at timestamptz;
BEGIN
  SELECT c.author_id, c.first_published_at, c.deleted_at
    INTO v_author_id, v_first_published_at, v_deleted_at
  FROM public.characters c
  WHERE c.id = p_character_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Character not found.';
  END IF;
  IF v_author_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Not allowed to delete this character.';
  END IF;
  IF v_deleted_at IS NOT NULL THEN
    RETURN v_deleted_at;
  END IF;

  v_deleted_at := now();

  UPDATE public.characters
  SET visibility = 'private',
      review_status = 'draft',
      deleted_at = v_deleted_at,
      deletion_reason = 'author_deleted'
  WHERE id = p_character_id;

  UPDATE public.character_stories
  SET visibility = 'private'
  WHERE character_id = p_character_id;

  UPDATE public.chat_sessions cs
  SET character_snapshot = COALESCE(cs.character_snapshot, '{}'::jsonb) ||
    jsonb_build_object(
      'authorId', v_author_id,
      'visibility', 'private',
      'firstPublishedAt', v_first_published_at,
      'deletedAt', v_deleted_at
    ),
    updated_at = now()
  WHERE cs.character_id = p_character_id;

  RETURN v_deleted_at;
END;
$$;

REVOKE ALL ON FUNCTION public.soft_delete_character(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.soft_delete_character(uuid) TO authenticated;
