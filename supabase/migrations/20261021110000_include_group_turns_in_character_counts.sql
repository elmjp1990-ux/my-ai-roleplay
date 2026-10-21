-- Extend cumulative character reply counts to group-roleplay messages.
CREATE OR REPLACE FUNCTION public.get_public_character_turn_count(p_character_id uuid)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT
    (SELECT count(m.id)::bigint
     FROM public.chat_sessions s
     LEFT JOIN public.chat_messages m ON m.session_id=s.id AND m.role='assistant'
     WHERE s.character_id=p_character_id)
    +
    (SELECT count(gm.id)::bigint
     FROM public.chat_group_messages gm
     WHERE gm.character_id=p_character_id AND gm.speaker_type='character');
$function$;

CREATE OR REPLACE FUNCTION public.get_character_turn_counts(p_character_ids uuid[])
RETURNS TABLE(character_id uuid, turn_count bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  WITH requested AS (
    SELECT DISTINCT unnest(coalesce(p_character_ids, ARRAY[]::uuid[])) AS character_id
  ), solo_counts AS (
    SELECT s.character_id, count(m.id)::bigint AS turn_count
    FROM public.chat_sessions s
    LEFT JOIN public.chat_messages m ON m.session_id=s.id AND m.role='assistant'
    JOIN requested r ON r.character_id=s.character_id
    GROUP BY s.character_id
  ), group_counts AS (
    SELECT gm.character_id, count(gm.id)::bigint AS turn_count
    FROM public.chat_group_messages gm
    JOIN requested r ON r.character_id=gm.character_id
    WHERE gm.speaker_type='character'
    GROUP BY gm.character_id
  )
  SELECT r.character_id, coalesce(sc.turn_count,0)+coalesce(gc.turn_count,0)
  FROM requested r
  LEFT JOIN solo_counts sc ON sc.character_id=r.character_id
  LEFT JOIN group_counts gc ON gc.character_id=r.character_id;
$function$;

REVOKE ALL ON FUNCTION public.get_public_character_turn_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_character_turn_count(uuid) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.get_character_turn_counts(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_character_turn_counts(uuid[]) TO anon, authenticated;
