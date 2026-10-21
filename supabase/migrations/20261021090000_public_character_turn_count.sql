-- Public aggregate only: never return chat content or per-user activity.
CREATE OR REPLACE FUNCTION public.get_public_character_turn_count(p_character_id uuid)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT count(*)::bigint
  FROM public.chat_messages AS m
  JOIN public.chat_sessions AS s ON s.id = m.session_id
  JOIN public.characters AS c ON c.id = s.character_id
  WHERE c.id = p_character_id
    AND c.visibility = 'public'
    AND c.review_status = 'approved'
    AND c.deleted_at IS NULL
    AND c.rights_confirmed IS TRUE
    AND s.deleted_at IS NULL
    AND m.deleted_at IS NULL
    AND m.role = 'assistant';
$function$;

REVOKE ALL ON FUNCTION public.get_public_character_turn_count(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_character_turn_count(uuid) TO anon, authenticated;
