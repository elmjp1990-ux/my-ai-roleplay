-- Bound public encounter schedule hydration to one RPC per 10-character page.
-- Return only the newest story row per character for the owner's 10-row character page.

CREATE OR REPLACE FUNCTION public.get_latest_owned_character_stories(p_character_ids uuid[])
RETURNS TABLE (
  character_id uuid,
  opening_message text,
  visibility text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT DISTINCT ON (s.character_id)
    s.character_id,
    s.opening_message,
    s.visibility,
    s.created_at
  FROM public.character_stories s
  JOIN public.characters c ON c.id = s.character_id
  WHERE p_character_ids IS NOT NULL
    AND pg_catalog.cardinality(p_character_ids) BETWEEN 1 AND 10
    AND s.character_id = ANY (p_character_ids)
    AND c.author_id = (SELECT auth.uid())
  ORDER BY s.character_id, s.created_at DESC, s.id DESC;
$$;

REVOKE ALL ON FUNCTION public.get_latest_owned_character_stories(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_latest_owned_character_stories(uuid[]) TO authenticated;

COMMENT ON FUNCTION public.get_latest_owned_character_stories(uuid[]) IS
  'Returns at most one newest story row per supplied character ID, limited to 10 IDs and the authenticated character owner. Uses invoker privileges and existing table RLS.';

CREATE OR REPLACE FUNCTION public.get_encounter_character_schedules(p_character_ids uuid[])
RETURNS TABLE (
  character_id uuid,
  weekday smallint,
  day_type text,
  start_time time,
  end_time time,
  location_key text,
  activity text,
  priority smallint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    s.character_id,
    s.weekday,
    s.day_type,
    s.start_time,
    s.end_time,
    s.location_key,
    s.activity,
    s.priority
  FROM public.characters c
  JOIN public.character_schedules s ON s.character_id = c.id
  WHERE p_character_ids IS NOT NULL
    AND pg_catalog.cardinality(p_character_ids) BETWEEN 1 AND 10
    AND c.id = ANY (p_character_ids)
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
  ORDER BY s.character_id, s.priority DESC, s.weekday NULLS FIRST, s.start_time;
$$;

REVOKE ALL ON FUNCTION public.get_encounter_character_schedules(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_encounter_character_schedules(uuid[]) TO anon, authenticated;

COMMENT ON FUNCTION public.get_encounter_character_schedules(uuid[]) IS
  'Batch counterpart to get_encounter_character_schedule. Returns active schedules only for public, non-deleted, approved, rights-confirmed characters; accepts at most 10 IDs and preserves the existing NSFW adult gate.';


-- Resolve the latest ordinary Story session in one owner-scoped query.
-- The candidate window and ordering mirror the previous two-query client flow.
CREATE OR REPLACE FUNCTION public.find_existing_story_chat_session(p_character_id uuid)
RETURNS TABLE (session_id uuid)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  WITH candidates AS (
    SELECT s.id, s.updated_at
    FROM public.chat_sessions s
    WHERE s.user_id = (SELECT auth.uid())
      AND s.character_id = p_character_id
      AND s.deleted_at IS NULL
      AND s.chat_mode <> 'encounter'
      AND jsonb_typeof(s.session_data -> 'encounter') IS DISTINCT FROM 'object'
      AND COALESCE(s.session_data ->> 'encounterMode', '') <> 'true'
      AND NULLIF(pg_catalog.btrim(s.session_data ->> 'encounterPlace'), '') IS NULL
    ORDER BY s.updated_at DESC, s.id DESC
    LIMIT 10
  ),
  latest_user_message AS (
    SELECT
      c.id,
      c.updated_at,
      message.created_at AS last_user_message_at
    FROM candidates c
    LEFT JOIN LATERAL (
      SELECT cm.created_at
      FROM public.chat_messages cm
      WHERE cm.session_id = c.id
        AND cm.role = 'user'
        AND cm.deleted_at IS NULL
      ORDER BY cm.created_at DESC, cm.id DESC
      LIMIT 1
    ) message ON TRUE
  )
  SELECT id
  FROM latest_user_message
  ORDER BY last_user_message_at DESC NULLS LAST, updated_at DESC, id DESC
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.find_existing_story_chat_session(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.find_existing_story_chat_session(uuid) TO authenticated;

COMMENT ON FUNCTION public.find_existing_story_chat_session(uuid) IS
  'Returns the most recently active player Story session among the newest 10 eligible non-Encounter sessions for auth.uid(). Uses invoker privileges and existing chat_sessions/chat_messages RLS.';
