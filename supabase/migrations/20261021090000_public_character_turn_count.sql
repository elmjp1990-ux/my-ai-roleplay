-- Aggregate only: return cumulative AI reply counts, never message content or user identity.
-- Counts remain available after a character is made private or soft-deleted.
CREATE OR REPLACE FUNCTION public.get_public_character_turn_count(p_character_id uuid)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT count(m.id)::bigint
  FROM public.chat_sessions AS s
  LEFT JOIN public.chat_messages AS m
    ON m.session_id = s.id
   AND m.role = 'assistant'
  WHERE s.character_id = p_character_id;
$function$;

REVOKE ALL ON FUNCTION public.get_public_character_turn_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_character_turn_count(uuid) TO anon, authenticated;

-- Batch version keeps the character grid to one RPC instead of one request per card.
CREATE OR REPLACE FUNCTION public.get_character_turn_counts(p_character_ids uuid[])
RETURNS TABLE(character_id uuid, turn_count bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT requested.character_id, count(m.id)::bigint AS turn_count
  FROM unnest(coalesce(p_character_ids, ARRAY[]::uuid[])) AS requested(character_id)
  LEFT JOIN public.chat_sessions AS s
    ON s.character_id = requested.character_id
  LEFT JOIN public.chat_messages AS m
    ON m.session_id = s.id
   AND m.role = 'assistant'
  GROUP BY requested.character_id;
$function$;

REVOKE ALL ON FUNCTION public.get_character_turn_counts(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_character_turn_counts(uuid[]) TO anon, authenticated;
