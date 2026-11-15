-- Group Story AI summaries share the single-chat five-turn cadence and model.
-- Ensure group phone notices are durable before backfilling member snapshots.
ALTER TABLE public.chat_group_members
  ADD COLUMN IF NOT EXISTS phone_notifications jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.chat_group_members
  DROP CONSTRAINT IF EXISTS chat_group_members_phone_notifications_array;
ALTER TABLE public.chat_group_members
  ADD CONSTRAINT chat_group_members_phone_notifications_array
  CHECK (jsonb_typeof(phone_notifications) = 'array');

-- Previous single-chat workers could mark an empty result as completed.
-- Make only those invalid batches retryable by the corrected worker.
DO $migration$
BEGIN
  IF to_regclass('public.ai_model_usage') IS NOT NULL THEN
    UPDATE public.ai_model_usage
    SET status = 'failed',
        processed_at = now()
    WHERE generation_type = 'memory_summary'
      AND status = 'completed'
      AND NULLIF(btrim(summary), '') IS NULL;
  END IF;
END;
$migration$;

-- Backfill legacy group phone notices; preserve non-empty member values.
-- Only copy non-empty arrays; leave empty/default rows untouched.
UPDATE public.chat_group_members
SET phone_notifications = COALESCE(character_snapshot->'phoneNotifications', character_snapshot->'phone_notifications')
WHERE phone_notifications = '[]'::jsonb
  AND CASE
    WHEN jsonb_typeof(COALESCE(character_snapshot->'phoneNotifications', character_snapshot->'phone_notifications')) = 'array'
      THEN jsonb_array_length(COALESCE(character_snapshot->'phoneNotifications', character_snapshot->'phone_notifications')) > 0
    ELSE false
  END;

CREATE TABLE IF NOT EXISTS public.chat_group_memory_summaries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  batch_number integer NOT NULL CHECK (batch_number > 0),
  source_turn_ids uuid[] NOT NULL CHECK (cardinality(source_turn_ids) = 5),
  summary text CHECK (summary IS NULL OR char_length(summary) BETWEEN 50 AND 150),
  important boolean NOT NULL DEFAULT false,
  user_edited boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'processing' CHECK (status IN ('processing', 'completed', 'failed')),
  model text NOT NULL DEFAULT 'openai/gpt-oss-20b',
  provider text,
  gateway_request_id text,
  prompt_tokens integer,
  completion_tokens integer,
  total_tokens integer,
  cost_usd numeric(14,8),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  UNIQUE (group_id, batch_number)
);

CREATE INDEX IF NOT EXISTS chat_group_memory_summaries_owner_batch_idx
  ON public.chat_group_memory_summaries (user_id, group_id, batch_number);

ALTER TABLE public.chat_group_memory_summaries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.chat_group_memory_summaries FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.chat_group_memory_summaries TO service_role;

CREATE OR REPLACE FUNCTION public.get_group_memory_summaries(p_group_id uuid)
RETURNS TABLE (
  batch_number integer,
  summary text,
  important boolean,
  user_edited boolean,
  memory_at timestamptz,
  generation_status text,
  completed_turn_count integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  WITH owned AS (
    SELECT g.id
    FROM public.chat_groups g
    WHERE g.id = p_group_id
      AND g.owner_id = (SELECT auth.uid())
      AND g.deleted_at IS NULL
  ),
  counts AS (
    SELECT count(*)::integer AS completed_count
    FROM public.chat_group_turns t
    JOIN owned o ON o.id = t.group_id
    WHERE t.status = 'completed'
  ),
  latest AS (
    SELECT s.status
    FROM public.chat_group_memory_summaries s
    JOIN owned o ON o.id = s.group_id
    ORDER BY s.batch_number DESC
    LIMIT 1
  ),
  completed AS (
    SELECT s.batch_number, s.summary, s.important, s.user_edited,
           COALESCE(s.processed_at, s.created_at) AS memory_at
    FROM public.chat_group_memory_summaries s
    JOIN owned o ON o.id = s.group_id
    WHERE s.status = 'completed'
      AND s.summary IS NOT NULL
      AND btrim(s.summary) <> ''
  )
  SELECT c.batch_number, c.summary, c.important, c.user_edited, c.memory_at,
         COALESCE((SELECT l.status FROM latest l),
           CASE WHEN n.completed_count >= 5 THEN 'pending' ELSE 'collecting' END),
         n.completed_count
  FROM completed c
  CROSS JOIN counts n
  UNION ALL
  SELECT NULL::integer, NULL::text, false, false, NULL::timestamptz,
         COALESCE((SELECT l.status FROM latest l),
           CASE WHEN n.completed_count >= 5 THEN 'pending' ELSE 'collecting' END),
         n.completed_count
  FROM owned
  CROSS JOIN counts n
  WHERE NOT EXISTS (SELECT 1 FROM completed)
  ORDER BY batch_number NULLS LAST;
$function$;

REVOKE ALL ON FUNCTION public.get_group_memory_summaries(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_group_memory_summaries(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_group_memory_summary_important(
  p_group_id uuid,
  p_batch_number integer,
  p_important boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_updated integer;
BEGIN
  IF auth.uid() IS NULL OR p_group_id IS NULL OR p_batch_number IS NULL OR p_important IS NULL THEN
    RAISE EXCEPTION 'invalid_group_memory_summary_request' USING ERRCODE = '22023';
  END IF;
  UPDATE public.chat_group_memory_summaries s
  SET important = p_important, updated_at = now()
  FROM public.chat_groups g
  WHERE s.group_id = p_group_id
    AND s.batch_number = p_batch_number
    AND s.status = 'completed'
    AND s.summary IS NOT NULL
    AND g.id = s.group_id
    AND g.owner_id = (SELECT auth.uid())
    AND g.deleted_at IS NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_group_memory_summary(
  p_group_id uuid,
  p_batch_number integer,
  p_summary text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_summary text := NULLIF(btrim(COALESCE(p_summary, '')), '');
  v_updated integer;
BEGIN
  IF auth.uid() IS NULL OR p_group_id IS NULL OR p_batch_number IS NULL THEN
    RAISE EXCEPTION 'invalid_group_memory_summary_request' USING ERRCODE = '22023';
  END IF;
  IF v_summary IS NOT NULL AND char_length(v_summary) NOT BETWEEN 50 AND 150 THEN
    RAISE EXCEPTION 'group_memory_summary_must_be_50_to_150_chars' USING ERRCODE = '22023';
  END IF;
  UPDATE public.chat_group_memory_summaries s
  SET summary = v_summary,
      important = CASE WHEN v_summary IS NULL THEN false ELSE s.important END,
      user_edited = true,
      updated_at = now()
  FROM public.chat_groups g
  WHERE s.group_id = p_group_id
    AND s.batch_number = p_batch_number
    AND s.status = 'completed'
    AND g.id = s.group_id
    AND g.owner_id = (SELECT auth.uid())
    AND g.deleted_at IS NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_group_memory_summary_important(uuid, integer, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_group_memory_summary(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_group_memory_summary_important(uuid, integer, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_group_memory_summary(uuid, integer, text) TO authenticated;
