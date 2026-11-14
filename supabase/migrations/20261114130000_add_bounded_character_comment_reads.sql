-- Add bounded comment reads without rewriting an already-applied historical migration.
-- Mirrors get_character_comments_safe's SECURITY DEFINER access and whisper masking.
CREATE OR REPLACE FUNCTION public.get_character_comments_safe_page(
  p_character_id uuid,
  p_limit integer DEFAULT 10,
  p_offset integer DEFAULT 0
)
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
  ORDER BY cm.created_at ASC, cm.id ASC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 10), 10))
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$function$;

REVOKE ALL ON FUNCTION public.get_character_comments_safe_page(uuid, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_character_comments_safe_page(uuid, integer, integer) TO authenticated;
