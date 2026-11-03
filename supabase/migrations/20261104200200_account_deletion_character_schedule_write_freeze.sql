-- PR #200: freeze character schedule reads/writes once account deletion is requested.
-- This closes both direct table-DML and SECURITY DEFINER RPC paths.
-- Apply after account_is_active() exists; validate only on disposable schema until approved.

ALTER POLICY character_schedules_select_author
  ON public.character_schedules
  USING (
    EXISTS (
      SELECT 1
      FROM public.characters AS c
      WHERE c.id = character_schedules.character_id
        AND c.author_id = (SELECT auth.uid())
        AND c.deleted_at IS NULL
    )
    AND public.account_is_active()
  );

ALTER POLICY character_schedules_insert_author
  ON public.character_schedules
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.characters AS c
      WHERE c.id = character_schedules.character_id
        AND c.author_id = (SELECT auth.uid())
        AND c.deleted_at IS NULL
    )
    AND public.account_is_active()
  );

ALTER POLICY character_schedules_update_author
  ON public.character_schedules
  USING (
    EXISTS (
      SELECT 1
      FROM public.characters AS c
      WHERE c.id = character_schedules.character_id
        AND c.author_id = (SELECT auth.uid())
        AND c.deleted_at IS NULL
    )
    AND public.account_is_active()
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.characters AS c
      WHERE c.id = character_schedules.character_id
        AND c.author_id = (SELECT auth.uid())
        AND c.deleted_at IS NULL
    )
    AND public.account_is_active()
  );

ALTER POLICY character_schedules_delete_author
  ON public.character_schedules
  USING (
    EXISTS (
      SELECT 1
      FROM public.characters AS c
      WHERE c.id = character_schedules.character_id
        AND c.author_id = (SELECT auth.uid())
        AND c.deleted_at IS NULL
    )
    AND public.account_is_active()
  );

CREATE OR REPLACE FUNCTION public.save_character_schedules(
  p_character_id uuid,
  p_schedules jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF NOT public.account_is_active() THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  IF p_character_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.characters AS c
    WHERE c.id = p_character_id
      AND c.author_id = v_uid
      AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Character not found or not owned by caller' USING ERRCODE = '42501';
  END IF;

  IF p_schedules IS NULL OR jsonb_typeof(p_schedules) <> 'array' THEN
    RAISE EXCEPTION 'Schedules must be a JSON array' USING ERRCODE = '22023';
  END IF;

  v_count := jsonb_array_length(p_schedules);
  IF v_count > 50 THEN
    RAISE EXCEPTION 'At most 50 schedule rows are allowed' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_schedules) AS e(value)
    WHERE jsonb_typeof(e.value) <> 'object'
      OR (e.value ? 'weekday' AND e.value->'weekday' <> 'null'::jsonb
          AND (jsonb_typeof(e.value->'weekday') <> 'number'
               OR (e.value->>'weekday') !~ '^[0-6]$'))
      OR COALESCE(e.value->>'day_type', 'any') NOT IN ('any', 'weekday', 'weekend')
      OR COALESCE(e.value->>'start_time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      OR COALESCE(e.value->>'end_time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      OR COALESCE(e.value->>'start_time', '') = COALESCE(e.value->>'end_time', '')
      OR COALESCE(e.value->>'location_key', '') !~ '^[A-Za-z0-9_-]{1,80}$'
      OR char_length(COALESCE(e.value->>'activity', '')) NOT BETWEEN 1 AND 300
  ) THEN
    RAISE EXCEPTION 'One or more schedule rows are invalid' USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.character_schedules
  WHERE character_id = p_character_id;

  INSERT INTO public.character_schedules (
    character_id, weekday, day_type, start_time, end_time,
    location_key, activity, priority, is_active
  )
  SELECT
    p_character_id,
    x.weekday,
    COALESCE(x.day_type, 'any'),
    x.start_time::time,
    x.end_time::time,
    x.location_key,
    x.activity,
    0,
    true
  FROM jsonb_to_recordset(p_schedules) AS x(
    weekday smallint,
    day_type text,
    start_time text,
    end_time text,
    location_key text,
    activity text
  );

  RETURN v_count;
END;
$function$;
