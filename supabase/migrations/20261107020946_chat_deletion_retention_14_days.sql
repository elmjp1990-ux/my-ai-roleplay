-- Standardize soft-deleted single and group chat retention to 14 days.
-- Existing queued/completed jobs are backfilled from their original deleted_at timestamp.
ALTER TABLE public.chat_deletion_jobs DROP CONSTRAINT chat_deletion_jobs_retention_window_check;

UPDATE public.chat_deletion_jobs
SET purge_after = deleted_at + interval '14 days',
    updated_at = clock_timestamp()
WHERE purge_after = deleted_at + interval '30 days';

ALTER TABLE public.chat_deletion_jobs
ADD CONSTRAINT chat_deletion_jobs_retention_window_check
CHECK (purge_after = deleted_at + interval '14 days');

CREATE OR REPLACE FUNCTION public.delete_chat_group_with_related_data(p_group_id uuid)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_owner_id uuid;
  v_deleted_at timestamptz;
  v_job_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests r
    WHERE r.user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  SELECT g.owner_id, g.deleted_at
    INTO v_owner_id, v_deleted_at
  FROM public.chat_groups g
  WHERE g.id = p_group_id
  FOR UPDATE;

  IF NOT FOUND OR v_owner_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'group_not_found_or_not_owned' USING ERRCODE = '42501';
  END IF;

  v_deleted_at := COALESCE(v_deleted_at, pg_catalog.statement_timestamp());

  INSERT INTO public.chat_deletion_jobs (
    resource_type, resource_id, owner_id, deleted_at, purge_after, status
  )
  VALUES (
    'group', p_group_id, v_user_id, v_deleted_at,
    v_deleted_at + interval '14 days', 'queued'
  )
  ON CONFLICT (resource_type, resource_id) DO NOTHING;

  SELECT j.id
    INTO v_job_id
  FROM public.chat_deletion_jobs j
  WHERE j.resource_type = 'group'
    AND j.resource_id = p_group_id
    AND j.owner_id = v_user_id
    AND j.deleted_at = v_deleted_at
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'chat_deletion_job_conflict' USING ERRCODE = '40001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.chat_memory_photos p
    WHERE p.group_id = p_group_id
      AND p.chat_type = 'group'
      AND p.owner_id = v_user_id
      AND left(p.storage_path, char_length(v_user_id::text) + 1) <> v_user_id::text || '/'
  ) THEN
    RAISE EXCEPTION 'chat_storage_path_owner_mismatch' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.chat_storage_deletion_jobs (
    deletion_job_id, bucket_id, object_path, resource_type, resource_id, owner_id
  )
  SELECT
    v_job_id, 'personax-memory-photos', p.storage_path,
    'group', p_group_id, v_user_id
  FROM public.chat_memory_photos p
  WHERE p.group_id = p_group_id
    AND p.chat_type = 'group'
    AND p.owner_id = v_user_id
  ON CONFLICT (bucket_id, object_path) DO NOTHING;

  IF EXISTS (
    SELECT 1
    FROM public.chat_storage_deletion_jobs sj
    JOIN public.chat_memory_photos p ON p.storage_path = sj.object_path
    WHERE p.group_id = p_group_id
      AND p.chat_type = 'group'
      AND p.owner_id = v_user_id
      AND (sj.owner_id <> v_user_id OR sj.deletion_job_id <> v_job_id)
  ) THEN
    RAISE EXCEPTION 'chat_storage_deletion_job_conflict' USING ERRCODE = '40001';
  END IF;

  UPDATE public.chat_groups g
  SET deleted_at = COALESCE(g.deleted_at, v_deleted_at),
      updated_at = pg_catalog.statement_timestamp()
  WHERE g.id = p_group_id
    AND g.owner_id = v_user_id;

  RETURN QUERY SELECT NULL::text WHERE false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_chat_session_content(p_session_id uuid)
 RETURNS TABLE(storage_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_owner_id uuid;
  v_deleted_at timestamptz;
  v_job_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication_required' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests r
    WHERE r.user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'account_deletion_pending' USING ERRCODE = '42501';
  END IF;

  SELECT s.user_id, s.deleted_at
    INTO v_owner_id, v_deleted_at
  FROM public.chat_sessions s
  WHERE s.id = p_session_id
  FOR UPDATE;

  IF NOT FOUND OR v_owner_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'session_not_found_or_not_owned' USING ERRCODE = '42501';
  END IF;

  v_deleted_at := COALESCE(v_deleted_at, pg_catalog.statement_timestamp());

  INSERT INTO public.chat_deletion_jobs (
    resource_type, resource_id, owner_id, deleted_at, purge_after, status
  )
  VALUES (
    'single_session', p_session_id, v_user_id, v_deleted_at,
    v_deleted_at + interval '14 days', 'queued'
  )
  ON CONFLICT (resource_type, resource_id) DO NOTHING;

  SELECT j.id
    INTO v_job_id
  FROM public.chat_deletion_jobs j
  WHERE j.resource_type = 'single_session'
    AND j.resource_id = p_session_id
    AND j.owner_id = v_user_id
    AND j.deleted_at = v_deleted_at
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'chat_deletion_job_conflict' USING ERRCODE = '40001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.chat_memory_photos p
    WHERE p.session_id = p_session_id
      AND p.chat_type = 'single'
      AND p.owner_id = v_user_id
      AND left(p.storage_path, char_length(v_user_id::text) + 1) <> v_user_id::text || '/'
  ) THEN
    RAISE EXCEPTION 'chat_storage_path_owner_mismatch' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.chat_storage_deletion_jobs (
    deletion_job_id, bucket_id, object_path, resource_type, resource_id, owner_id
  )
  SELECT
    v_job_id, 'personax-memory-photos', p.storage_path,
    'single_session', p_session_id, v_user_id
  FROM public.chat_memory_photos p
  WHERE p.session_id = p_session_id
    AND p.chat_type = 'single'
    AND p.owner_id = v_user_id
  ON CONFLICT (bucket_id, object_path) DO NOTHING;

  IF EXISTS (
    SELECT 1
    FROM public.chat_storage_deletion_jobs sj
    JOIN public.chat_memory_photos p ON p.storage_path = sj.object_path
    WHERE p.session_id = p_session_id
      AND p.chat_type = 'single'
      AND p.owner_id = v_user_id
      AND (sj.owner_id <> v_user_id OR sj.deletion_job_id <> v_job_id)
  ) THEN
    RAISE EXCEPTION 'chat_storage_deletion_job_conflict' USING ERRCODE = '40001';
  END IF;

  UPDATE public.chat_sessions s
  SET deleted_at = COALESCE(s.deleted_at, v_deleted_at),
      updated_at = pg_catalog.statement_timestamp()
  WHERE s.id = p_session_id
    AND s.user_id = v_user_id;

  RETURN QUERY SELECT NULL::text WHERE false;
END;
$function$;
