-- Fetch at most one latest message preview for each of up to ten owned groups.
-- SECURITY INVOKER preserves the caller's table grants and RLS policies.
CREATE OR REPLACE FUNCTION public.get_my_group_list_previews(p_group_ids uuid[])
RETURNS TABLE (
  group_id uuid,
  content text,
  speaker_type text,
  created_at timestamptz,
  sequence_no integer
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NULL
    OR p_group_ids IS NULL
    OR cardinality(p_group_ids) NOT BETWEEN 1 AND 10
  THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT DISTINCT ON (m.group_id)
    m.group_id,
    m.content,
    m.speaker_type,
    m.created_at,
    m.sequence_no
  FROM public.chat_groups AS g
  JOIN public.chat_group_messages AS m
    ON m.group_id = g.id
  WHERE g.id = ANY (p_group_ids)
    AND g.owner_id = auth.uid()
    AND g.archived_at IS NULL
    AND g.deleted_at IS NULL
    AND m.deleted_at IS NULL
  ORDER BY m.group_id, m.created_at DESC, m.sequence_no DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_group_list_previews(uuid[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_group_list_previews(uuid[])
  TO authenticated;
