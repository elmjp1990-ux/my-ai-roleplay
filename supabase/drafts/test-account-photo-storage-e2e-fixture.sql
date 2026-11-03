-- DRAFT TEST FIXTURE ONLY. Run only in the disposable local Supabase E2E workflow.
-- Seed a real synthetic chat photo and call the exact helper invoked by
-- prepare_account_deletion(); the Storage API E2E consumes this resulting queue row.
DO $fixture$
DECLARE
  v_owner uuid := '10000000-0000-4000-8000-000000000031';
  v_session uuid := '50000000-0000-4000-8000-000000000031';
  v_photo uuid := 'c0000000-0000-4000-8000-000000000031';
  v_requested_at timestamptz := pg_catalog.statement_timestamp() - interval '31 days';
  v_queued integer;
BEGIN
  INSERT INTO auth.users (id) VALUES (v_owner)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.profiles (id, handle, nickname)
  VALUES (v_owner, 'pr200-storage-e2e', 'PR200 Storage E2E')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.chat_sessions (
    id, user_id, character_name, chat_mode
  ) VALUES (
    v_session, v_owner, 'Account photo Storage E2E', 'story'
  );

  INSERT INTO public.chat_memory_photos (
    id, owner_id, chat_type, session_id, storage_path, caption
  ) VALUES (
    v_photo, v_owner, 'single', v_session,
    v_owner::text || '/single/' || v_session::text || '/' || v_photo::text || '.jpg',
    'synthetic account deletion photo Storage E2E'
  );

  v_queued := private.enqueue_account_chat_memory_photo_cleanup(
    v_owner, v_requested_at, v_requested_at + interval '5 minutes'
  );

  IF v_queued <> 1 OR NOT EXISTS (
    SELECT 1
    FROM public.chat_storage_deletion_jobs AS sj
    JOIN public.chat_deletion_jobs AS j ON j.id = sj.deletion_job_id
    WHERE sj.bucket_id = 'personax-memory-photos'
      AND sj.object_path = v_owner::text || '/' || v_session::text || '/' || v_photo::text || '.jpg'
      AND sj.owner_id = v_owner
      AND sj.status = 'queued'
      AND j.resource_type = 'single_session'
      AND j.resource_id = v_session
      AND j.deleted_at = v_requested_at
      AND j.purge_after = v_requested_at + interval '30 days'
      AND j.status = 'queued'
  ) THEN
    RAISE EXCEPTION 'account_photo_helper_must_create_the_30_day_storage_queue_row';
  END IF;
END;
$fixture$;
