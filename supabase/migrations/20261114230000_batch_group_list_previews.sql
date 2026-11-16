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
  SELECT
    g.id,
    latest.content,
    latest.speaker_type,
    latest.created_at,
    latest.sequence_no
  FROM public.chat_groups AS g
  CROSS JOIN LATERAL (
    SELECT m.content, m.speaker_type, m.created_at, m.sequence_no
    FROM public.chat_group_messages AS m
    WHERE m.group_id = g.id
      AND m.deleted_at IS NULL
    ORDER BY m.created_at DESC, m.sequence_no DESC
    LIMIT 1
  ) AS latest
  WHERE g.id = ANY (p_group_ids)
    AND g.owner_id = auth.uid()
    AND g.archived_at IS NULL
    AND g.deleted_at IS NULL
  ORDER BY g.id;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_group_list_previews(uuid[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_group_list_previews(uuid[])
  TO authenticated;
