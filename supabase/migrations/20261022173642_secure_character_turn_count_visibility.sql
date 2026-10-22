-- Restrict character turn-count RPCs to public characters or the authenticated owner.
-- Deleted characters intentionally return no count to anyone, including the former author.
CREATE OR REPLACE FUNCTION public.get_character_turn_counts(p_character_ids uuid[])
RETURNS TABLE(character_id uuid, turn_count bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  WITH requested AS (
    SELECT DISTINCT unnest(coalesce(p_character_ids, ARRAY[]::uuid[])) AS character_id
  ),
  allowed AS (
    SELECT c.id AS character_id
    FROM public.characters AS c
    JOIN requested AS r ON r.character_id = c.id
    WHERE c.deleted_at IS NULL
      AND (
        c.visibility = 'public'
        OR (
          (select auth.uid()) IS NOT NULL
          AND c.author_id = (select auth.uid())
        )
      )
  ),
  solo_counts AS (
    SELECT s.character_id, count(m.id)::bigint AS turn_count
    FROM public.chat_sessions AS s
    LEFT JOIN public.chat_messages AS m
      ON m.session_id = s.id
     AND m.role = 'assistant'
    JOIN allowed AS a ON a.character_id = s.character_id
    GROUP BY s.character_id
  ),
  group_counts AS (
    SELECT gm.character_id, count(gm.id)::bigint AS turn_count
    FROM public.chat_group_messages AS gm
    JOIN allowed AS a ON a.character_id = gm.character_id
    WHERE gm.speaker_type = 'character'
    GROUP BY gm.character_id
  )
  SELECT a.character_id,
         coalesce(sc.turn_count, 0) + coalesce(gc.turn_count, 0) AS turn_count
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
      WHERE s.character_id = c.id
    )
    +
    (
      SELECT count(gm.id)::bigint
      FROM public.chat_group_messages AS gm
      WHERE gm.character_id = c.id
        AND gm.speaker_type = 'character'
    )
  FROM public.characters AS c
  WHERE c.id = p_character_id
    AND c.visibility = 'public'
    AND c.deleted_at IS NULL;
$function$;

REVOKE ALL ON FUNCTION public.get_character_turn_counts(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_public_character_turn_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_character_turn_counts(uuid[]) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_public_character_turn_count(uuid) TO anon, authenticated, service_role;
