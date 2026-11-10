-- Store the user's important-memory choice on each generated Story summary.
-- The usage ledger remains service-role-only; clients use owner-checked RPCs.
BEGIN;

ALTER TABLE public.ai_model_usage
  ADD COLUMN IF NOT EXISTS important boolean NOT NULL DEFAULT false;

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
  ORDER BY u.batch_number ASC;
$$;

REVOKE ALL ON FUNCTION public.get_story_memory_summaries(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_story_memory_summaries(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_story_memory_summary_important(
  p_session_id uuid,
  p_batch_number integer,
  p_important boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_updated integer := 0;
BEGIN
  IF auth.uid() IS NULL OR p_batch_number IS NULL OR p_batch_number < 1 OR p_important IS NULL THEN
    RETURN false;
  END IF;

  UPDATE public.ai_model_usage u
  SET important = p_important
  WHERE u.session_id = p_session_id
    AND u.user_id = (SELECT auth.uid())
    AND u.generation_type = 'memory_summary'
    AND u.batch_number = p_batch_number
    AND u.status = 'completed'
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

REVOKE ALL ON FUNCTION public.set_story_memory_summary_important(uuid, integer, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_story_memory_summary_important(uuid, integer, boolean) TO authenticated;

COMMIT;
