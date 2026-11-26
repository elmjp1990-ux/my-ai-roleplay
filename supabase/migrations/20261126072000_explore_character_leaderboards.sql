-- Global Explore leaderboards with durable Taiwan-local daily turn aggregates.
-- Daily rows survive chat transcript deletion/purge; no user identifiers or message text are stored.

CREATE TABLE IF NOT EXISTS public.character_turn_daily_stats (
  character_id uuid NOT NULL REFERENCES public.characters(id) ON DELETE CASCADE,
  activity_date date NOT NULL,
  turn_count bigint NOT NULL DEFAULT 0 CHECK (turn_count >= 0),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CONSTRAINT character_turn_daily_stats_pkey PRIMARY KEY (character_id, activity_date)
);

CREATE INDEX IF NOT EXISTS character_turn_daily_stats_date_character_idx
  ON public.character_turn_daily_stats (activity_date DESC, character_id);

ALTER TABLE public.character_turn_daily_stats ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.character_turn_daily_stats
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON TABLE public.character_turn_daily_stats IS
  'Daily aggregate of completed character replies in Asia/Taipei dates. Contains no user IDs or transcript content and is retained when chats are deleted.';

-- Backfill messages that still exist, including messages whose parent chat has
-- already been soft-deleted but has not yet reached transcript purge.
WITH daily_events AS (
  SELECT s.character_id,
         (m.created_at AT TIME ZONE 'Asia/Taipei')::date AS activity_date,
         pg_catalog.count(*)::bigint AS turn_count
  FROM public.chat_messages AS m
  JOIN public.chat_sessions AS s ON s.id = m.session_id
  WHERE m.role = 'assistant' AND m.deleted_at IS NULL
  GROUP BY s.character_id, (m.created_at AT TIME ZONE 'Asia/Taipei')::date
  UNION ALL
  SELECT gm.character_id,
         (gm.created_at AT TIME ZONE 'Asia/Taipei')::date AS activity_date,
         pg_catalog.count(*)::bigint AS turn_count
  FROM public.chat_group_messages AS gm
  WHERE gm.speaker_type = 'character'
    AND gm.character_id IS NOT NULL
    AND gm.deleted_at IS NULL
  GROUP BY gm.character_id, (gm.created_at AT TIME ZONE 'Asia/Taipei')::date
)
INSERT INTO public.character_turn_daily_stats(character_id, activity_date, turn_count)
SELECT character_id, activity_date, pg_catalog.sum(turn_count)::bigint
FROM daily_events
GROUP BY character_id, activity_date
ON CONFLICT (character_id, activity_date) DO UPDATE
SET turn_count = EXCLUDED.turn_count,
    updated_at = pg_catalog.now();

CREATE OR REPLACE FUNCTION private.record_character_turn_daily_stat()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_character_id uuid;
  v_activity_date date;
  v_delta bigint := 0;
BEGIN
  IF TG_TABLE_NAME = 'chat_messages' THEN
    SELECT s.character_id INTO v_character_id
    FROM public.chat_sessions AS s
    WHERE s.id = NEW.session_id;
  ELSE
    v_character_id := NEW.character_id;
  END IF;

  IF v_character_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.deleted_at IS NULL THEN v_delta := 1; END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
      v_delta := -1;
    ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
      v_delta := 1;
    END IF;
  END IF;

  IF v_delta = 0 THEN
    RETURN NEW;
  END IF;

  v_activity_date := (NEW.created_at AT TIME ZONE 'Asia/Taipei')::date;

  INSERT INTO public.character_turn_daily_stats(character_id, activity_date, turn_count)
  VALUES (v_character_id, v_activity_date, v_delta)
  ON CONFLICT (character_id, activity_date) DO UPDATE
  SET turn_count = pg_catalog.greatest(
        0,
        public.character_turn_daily_stats.turn_count + EXCLUDED.turn_count
      ),
      updated_at = pg_catalog.now();

  DELETE FROM public.character_turn_daily_stats
  WHERE character_id = v_character_id
    AND activity_date = v_activity_date
    AND turn_count = 0;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION private.record_character_turn_daily_stat()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS chat_messages_character_turn_daily_stat
  ON public.chat_messages;
CREATE TRIGGER chat_messages_character_turn_daily_stat
AFTER INSERT OR UPDATE OF deleted_at ON public.chat_messages
FOR EACH ROW EXECUTE FUNCTION private.record_character_turn_daily_stat();

DROP TRIGGER IF EXISTS chat_group_messages_character_turn_daily_stat
  ON public.chat_group_messages;
CREATE TRIGGER chat_group_messages_character_turn_daily_stat
AFTER INSERT OR UPDATE OF deleted_at ON public.chat_group_messages
FOR EACH ROW EXECUTE FUNCTION private.record_character_turn_daily_stat();

CREATE OR REPLACE FUNCTION public.get_public_character_leaderboard(
  p_period text DEFAULT 'all',
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0,
  p_tags text[] DEFAULT NULL,
  p_search text DEFAULT NULL
)
RETURNS TABLE(character_id uuid, turn_count bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  WITH params AS (
    SELECT
      COALESCE(p_period, 'all') AS period,
      (pg_catalog.now() AT TIME ZONE 'Asia/Taipei')::date AS local_today,
      CASE
        WHEN p_period = 'month'
          THEN pg_catalog.date_trunc('month', pg_catalog.now() AT TIME ZONE 'Asia/Taipei')::date
        WHEN p_period = 'week'
          THEN ((pg_catalog.now() AT TIME ZONE 'Asia/Taipei')::date
            - (pg_catalog.extract(isodow FROM (pg_catalog.now() AT TIME ZONE 'Asia/Taipei'))::integer - 1))
        ELSE (pg_catalog.now() AT TIME ZONE 'Asia/Taipei')::date
      END AS period_start
  ),
  allowed AS (
    SELECT c.id AS character_id, c.first_published_at
    FROM public.characters AS c
    CROSS JOIN params AS p
    WHERE c.visibility = 'public'
      AND c.deleted_at IS NULL
      AND (
        c.is_nsfw IS NOT TRUE
        OR ((SELECT auth.uid()) IS NOT NULL AND private.current_user_is_adult())
      )
      AND (
        COALESCE(pg_catalog.cardinality(p_tags), 0) = 0
        OR c.tags @> p_tags
      )
      AND (
        NULLIF(pg_catalog.btrim(p_search), '') IS NULL
        OR c.name ILIKE '%' || pg_catalog.btrim(p_search) || '%'
        OR EXISTS (
          SELECT 1
          FROM pg_catalog.unnest(COALESCE(c.tags, ARRAY[]::text[])) AS tag(value)
          WHERE tag.value ILIKE '%' || pg_catalog.btrim(p_search) || '%'
        )
      )
      AND p.period IN ('all', 'month', 'week')
  ),
  all_time AS (
    SELECT counts.character_id, counts.turn_count
    FROM public.get_character_turn_counts(
      ARRAY(SELECT a.character_id FROM allowed AS a)
    ) AS counts
    CROSS JOIN params AS p
    WHERE p.period = 'all'
  ),
  period_counts AS (
    SELECT d.character_id, pg_catalog.sum(d.turn_count)::bigint AS turn_count
    FROM public.character_turn_daily_stats AS d
    JOIN allowed AS a ON a.character_id = d.character_id
    CROSS JOIN params AS p
    WHERE p.period IN ('month', 'week')
      AND d.activity_date >= p.period_start
      AND d.activity_date <= p.local_today
    GROUP BY d.character_id
  ),
  counts AS (
    SELECT * FROM all_time
    UNION ALL
    SELECT * FROM period_counts
  )
  SELECT c.character_id, c.turn_count
  FROM counts AS c
  WHERE c.turn_count > 0
  ORDER BY c.turn_count DESC, c.character_id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
  OFFSET LEAST(GREATEST(COALESCE(p_offset, 0), 0), 10000);
$function$;

REVOKE ALL ON FUNCTION public.get_public_character_leaderboard(text, integer, integer, text[], text[])
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_character_leaderboard(text, integer, integer, text[], text[])
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_public_character_leaderboard(text, integer, integer, text[], text[]) IS
  'Returns globally ranked public characters by completed AI reply count: all-time uses the canonical cumulative count RPC; month/week use durable Asia/Taipei daily aggregates. Week starts Monday.';
