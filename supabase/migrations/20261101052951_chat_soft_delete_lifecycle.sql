-- PR #200: switch single/group chat deletion to the shared 30-day soft-delete queue.
-- Keep the legacy RPC return shape for client compatibility; it returns no Storage paths
-- because clients must no longer delete chat-memory objects immediately.

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

  -- Parent-first lock serializes deletion with the new reservation/writer gates.
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
    v_deleted_at + interval '30 days', 'queued'
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

  -- Preserve all content during the 30-day retention window.
  RETURN QUERY SELECT NULL::text WHERE false;
END;
$function$;

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

  -- Parent-first lock serializes deletion with group-turn writers.
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
    v_deleted_at + interval '30 days', 'queued'
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

  -- Preserve all group content and character snapshots during the 30-day window.
  RETURN QUERY SELECT NULL::text WHERE false;
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_chat_session_content(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_chat_group_with_related_data(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_chat_session_content(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_chat_group_with_related_data(uuid) TO authenticated, service_role;

-- Restrictive policies add an AND gate to the existing owner/account policies.
-- Deleted parents become invisible and immutable immediately.
CREATE POLICY chat_sessions_active_lifecycle_guard
  ON public.chat_sessions AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (deleted_at IS NULL)
  WITH CHECK (deleted_at IS NULL);

CREATE POLICY chat_messages_active_session_lifecycle_guard
  ON public.chat_messages AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chat_sessions s
    WHERE s.id = chat_messages.session_id AND s.deleted_at IS NULL
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.chat_sessions s
    WHERE s.id = chat_messages.session_id AND s.deleted_at IS NULL
  ));

CREATE POLICY chat_message_versions_active_session_lifecycle_guard
  ON public.chat_message_versions AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1
    FROM public.chat_messages m
    JOIN public.chat_sessions s ON s.id = m.session_id
    WHERE m.id = chat_message_versions.message_id
      AND s.deleted_at IS NULL
  ))
  WITH CHECK (EXISTS (
    SELECT 1
    FROM public.chat_messages m
    JOIN public.chat_sessions s ON s.id = m.session_id
    WHERE m.id = chat_message_versions.message_id
      AND s.deleted_at IS NULL
  ));

CREATE POLICY ai_generation_records_active_session_lifecycle_guard
  ON public.ai_generation_records AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chat_sessions s
    WHERE s.id = ai_generation_records.session_id AND s.deleted_at IS NULL
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.chat_sessions s
    WHERE s.id = ai_generation_records.session_id AND s.deleted_at IS NULL
  ));

CREATE POLICY chat_groups_active_lifecycle_guard
  ON public.chat_groups AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (deleted_at IS NULL)
  WITH CHECK (deleted_at IS NULL);

DROP POLICY IF EXISTS chat_groups_owner_delete ON public.chat_groups;
REVOKE DELETE ON TABLE public.chat_groups FROM authenticated, anon;

CREATE POLICY chat_group_members_active_group_lifecycle_guard
  ON public.chat_group_members AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_members.group_id AND g.deleted_at IS NULL
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_members.group_id AND g.deleted_at IS NULL
  ));

CREATE POLICY chat_group_messages_active_group_lifecycle_guard
  ON public.chat_group_messages AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_messages.group_id AND g.deleted_at IS NULL
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_messages.group_id AND g.deleted_at IS NULL
  ));

CREATE POLICY chat_group_scenes_active_group_lifecycle_guard
  ON public.chat_group_scenes AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_scenes.group_id AND g.deleted_at IS NULL
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_scenes.group_id AND g.deleted_at IS NULL
  ));

CREATE POLICY chat_group_turns_active_group_lifecycle_guard
  ON public.chat_group_turns AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_turns.group_id AND g.deleted_at IS NULL
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_turns.group_id AND g.deleted_at IS NULL
  ));

CREATE POLICY chat_group_diary_active_group_lifecycle_guard
  ON public.chat_group_diary AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_diary.group_id AND g.deleted_at IS NULL
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_diary.group_id AND g.deleted_at IS NULL
  ));

CREATE POLICY chat_group_memory_photos_active_group_lifecycle_guard
  ON public.chat_group_memory_photos AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_memory_photos.group_id AND g.deleted_at IS NULL
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = chat_group_memory_photos.group_id AND g.deleted_at IS NULL
  ));

CREATE POLICY chat_memory_photos_active_parent_lifecycle_guard
  ON public.chat_memory_photos AS RESTRICTIVE
  FOR ALL TO authenticated
  USING (
    (chat_type = 'single' AND EXISTS (
      SELECT 1 FROM public.chat_sessions s
      WHERE s.id = chat_memory_photos.session_id AND s.deleted_at IS NULL
    ))
    OR
    (chat_type = 'group' AND EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = chat_memory_photos.group_id AND g.deleted_at IS NULL
    ))
  )
  WITH CHECK (
    (chat_type = 'single' AND EXISTS (
      SELECT 1 FROM public.chat_sessions s
      WHERE s.id = chat_memory_photos.session_id AND s.deleted_at IS NULL
    ))
    OR
    (chat_type = 'group' AND EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = chat_memory_photos.group_id AND g.deleted_at IS NULL
    ))
  );
