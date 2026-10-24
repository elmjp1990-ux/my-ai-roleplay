-- Keep NSFW age restrictions consistent across SECURITY DEFINER RPCs.
-- These functions bypass table RLS, so their own public-character filters must
-- enforce the same adult-only rule as the characters and Storage policies.
-- Character owners can still read their own comments/counts for management.

CREATE OR REPLACE FUNCTION public.get_character_comments_safe(p_character_id uuid)
RETURNS TABLE(
  id uuid,
  character_id uuid,
  author_id uuid,
  content text,
  parent_id uuid,
  is_whisper boolean,
  is_deleted boolean,
  created_at timestamptz,
  updated_at timestamptz,
  is_redacted boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  WITH me AS (SELECT auth.uid() AS uid),
  ch AS (
    SELECT c.id, c.author_id AS character_author_id
    FROM public.characters c
    WHERE c.id = p_character_id
      AND (
        c.author_id = (SELECT auth.uid())
        OR (
          c.visibility = 'public'
          AND c.deleted_at IS NULL
          AND (
            c.is_nsfw IS NOT TRUE
            OR (
              (SELECT auth.uid()) IS NOT NULL
              AND private.current_user_is_adult()
            )
          )
        )
      )
  )
  SELECT
    cm.id,
    cm.character_id,
    cm.author_id,
    CASE
      WHEN cm.is_deleted THEN '該筆評論已被刪除'
      WHEN private.comment_is_whisper_thread(cm.id)
       AND cm.author_id IS DISTINCT FROM me.uid
       AND ch.character_author_id IS DISTINCT FROM me.uid
       AND COALESCE(parent.author_id, cm.author_id) IS DISTINCT FROM me.uid
        THEN '這是一則悄悄話留言'
      ELSE cm.content
    END,
    cm.parent_id,
    cm.is_whisper,
    cm.is_deleted,
    cm.created_at,
    cm.updated_at,
    (
      NOT cm.is_deleted
      AND private.comment_is_whisper_thread(cm.id)
      AND cm.author_id IS DISTINCT FROM me.uid
      AND ch.character_author_id IS DISTINCT FROM me.uid
      AND COALESCE(parent.author_id, cm.author_id) IS DISTINCT FROM me.uid
    ) AS is_redacted
  FROM public.character_comments cm
  JOIN ch ON ch.id = cm.character_id
  CROSS JOIN me
  LEFT JOIN public.character_comments parent ON parent.id = cm.parent_id
  WHERE cm.character_id = p_character_id
  ORDER BY cm.created_at ASC;
$function$;

CREATE OR REPLACE FUNCTION public.get_character_turn_counts(p_character_ids uuid[])
RETURNS TABLE(character_id uuid, turn_count bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  WITH requested AS (
    SELECT DISTINCT unnest(COALESCE(p_character_ids, ARRAY[]::uuid[])) AS character_id
  ),
  allowed AS (
    SELECT c.id AS character_id
    FROM public.characters AS c
    JOIN requested AS r ON r.character_id = c.id
    WHERE c.deleted_at IS NULL
      AND (
        c.author_id = (SELECT auth.uid())
        OR (
          c.visibility = 'public'
          AND (
            c.is_nsfw IS NOT TRUE
            OR (
              (SELECT auth.uid()) IS NOT NULL
              AND private.current_user_is_adult()
            )
          )
        )
      )
  ),
  solo_counts AS (
    SELECT s.character_id, count(m.id)::bigint AS turn_count
    FROM public.chat_sessions AS s
    LEFT JOIN public.chat_messages AS m
      ON m.session_id = s.id
     AND m.role = 'assistant'
     AND m.deleted_at IS NULL
    JOIN allowed AS a ON a.character_id = s.character_id
    WHERE s.deleted_at IS NULL
    GROUP BY s.character_id
  ),
  group_counts AS (
    SELECT gm.character_id, count(gm.id)::bigint AS turn_count
    FROM public.chat_group_messages AS gm
    JOIN allowed AS a ON a.character_id = gm.character_id
    WHERE gm.speaker_type = 'character'
      AND gm.deleted_at IS NULL
    GROUP BY gm.character_id
  )
  SELECT a.character_id,
         COALESCE(sc.turn_count, 0) + COALESCE(gc.turn_count, 0) AS turn_count
  FROM allowed AS a
  LEFT JOIN solo_counts AS sc ON sc.character_id = a.character_id
  LEFT JOIN group_counts AS gc ON gc.character_id = a.character_id;
$function$;

CREATE OR REPLACE FUNCTION public.get_public_character_turn_count(p_character_id uuid)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT
    (
      SELECT count(m.id)::bigint
      FROM public.chat_sessions AS s
      LEFT JOIN public.chat_messages AS m
        ON m.session_id = s.id
       AND m.role = 'assistant'
       AND m.deleted_at IS NULL
      WHERE s.character_id = c.id
        AND s.deleted_at IS NULL
    )
    +
    (
      SELECT count(gm.id)::bigint
      FROM public.chat_group_messages AS gm
      WHERE gm.character_id = c.id
        AND gm.speaker_type = 'character'
        AND gm.deleted_at IS NULL
    )
  FROM public.characters AS c
  WHERE c.id = p_character_id
    AND c.visibility = 'public'
    AND c.deleted_at IS NULL
    AND (
      c.is_nsfw IS NOT TRUE
      OR (
        (SELECT auth.uid()) IS NOT NULL
        AND private.current_user_is_adult()
      )
    );
$function$;
