-- Store a cleared Story memory as an empty summary string so the
-- completed AI usage ledger row remains valid and is not regenerated.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_story_memory_summaries(p_session_id uuid)
RETURNS TABLE (
  batch_number integer,
  summary text,
  important boolean,
  memory_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    u.batch_number,
    u.summary,
    u.important,
    COALESCE(u.processed_at, u.created_at) AS memory_at
  FROM public.ai_model_usage u
  JOIN public.chat_sessions s ON s.id = u.session_id
  WHERE u.session_id = p_session_id
    AND u.user_id = (SELECT auth.uid())
    AND s.user_id = (SELECT auth.uid())
    AND s.chat_mode = 'story'
    AND s.deleted_at IS NULL
    AND u.generation_type = 'memory_summary'
    AND u.status = 'completed'
    AND u.summary IS NOT NULL
    AND btrim(u.summary) <> ''
  ORDER BY u.batch_number ASC;
$$;

REVOKE ALL ON FUNCTION public.get_story_memory_summaries(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_story_memory_summaries(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_story_memory_summary(
  p_session_id uuid,
  p_batch_number integer,
  p_summary text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_summary text := NULLIF(btrim(COALESCE(p_summary, '')), '');
  v_other_chars integer := 0;
  v_updated integer := 0;
BEGIN
  IF auth.uid() IS NULL
    OR p_session_id IS NULL
    OR p_batch_number IS NULL
    OR p_batch_number < 1
    OR char_length(COALESCE(v_summary, '')) > 1000
  THEN
    RETURN false;
  END IF;

  SELECT COALESCE(SUM(char_length(u.summary)), 0)::integer
    INTO v_other_chars
  FROM public.ai_model_usage u
  WHERE u.session_id = p_session_id
    AND u.user_id = (SELECT auth.uid())
    AND u.generation_type = 'memory_summary'
    AND u.status = 'completed'
    AND u.batch_number <> p_batch_number
    AND u.summary IS NOT NULL
    AND btrim(u.summary) <> '';

  IF v_other_chars + char_length(COALESCE(v_summary, '')) > 10000 THEN
    RETURN false;
  END IF;

  UPDATE public.ai_model_usage u
  SET summary = COALESCE(v_summary, ''),
      important = CASE WHEN v_summary IS NULL THEN false ELSE u.important END
  WHERE u.session_id = p_session_id
    AND u.user_id = (SELECT auth.uid())
    AND u.generation_type = 'memory_summary'
    AND u.batch_number = p_batch_number
    AND u.status = 'completed'
    AND u.summary IS NOT NULL
    AND btrim(u.summary) <> ''
    AND EXISTS (
      SELECT 1
      FROM public.chat_sessions s
      WHERE s.id = u.session_id
        AND s.user_id = (SELECT auth.uid())
        AND s.chat_mode = 'story'
        AND s.deleted_at IS NULL
    );

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.update_story_memory_summary(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_story_memory_summary(uuid, integer, text) TO authenticated;

COMMIT;
