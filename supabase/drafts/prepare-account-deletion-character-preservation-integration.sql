-- DRAFT ONLY — NOT AN ACTIVE MIGRATION.
-- Exact prepare_account_deletion(uuid) replacement based on the live test DB
-- pg_get_functiondef() inspected 2026-11-02, with character-preservation calls.
-- Do not execute against hosted Supabase. Requires the companion
-- account-deletion-character-preservation-draft.sql to be reviewed and replayed
-- on a disposable local database first.
--
-- Retry safety:
--   1. An already-deleting batch returns without requiring the profile row.
--   2. If legacy deleting batches still have author-owned characters, archive them
--      first (only when such rows exist); this is safe even after Auth deletion.
--   3. Existing archived/archiving batch and new-batch paths call the helper before
--      any irreversible cleanup. Both calls are in this same function transaction.
--
-- This is a complete replacement of the current live function definition, not
-- a partial snippet. Re-diff against pg_get_functiondef() immediately before use.

-- Queue account-owned chat-memory photo paths only when the irreversible account
-- deletion prepare step begins (after the 30-day recovery window). A cancellation
-- before this point creates no photo cleanup work. Queue rows survive Auth cascades.
CREATE OR REPLACE FUNCTION private.enqueue_account_chat_memory_photo_cleanup(
  p_user_id uuid,
  p_requested_at timestamptz,
  p_scheduled_for timestamptz
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_photo record;
  v_parent_owner uuid;
  v_parent_deleted_at timestamptz;
  v_resource_type text;
  v_resource_id uuid;
  v_deleted_at timestamptz;
  v_job_id uuid;
  v_job public.chat_deletion_jobs%ROWTYPE;
  v_storage_job public.chat_storage_deletion_jobs%ROWTYPE;
  v_queued integer := 0;
BEGIN
  IF p_user_id IS NULL OR p_requested_at IS NULL OR p_scheduled_for IS NULL
     OR p_scheduled_for <= p_requested_at THEN
    RAISE EXCEPTION 'account_chat_photo_retention_window_mismatch';
  END IF;

  FOR v_photo IN
    SELECT p.id, p.owner_id, p.chat_type, p.session_id, p.group_id, p.storage_path
    FROM public.chat_memory_photos AS p
    WHERE p.owner_id = p_user_id
    ORDER BY p.chat_type, COALESCE(p.session_id, p.group_id), p.id
    FOR UPDATE
  LOOP
    IF v_photo.storage_path !~ ('^' || p_user_id::text || '/')
       OR char_length(v_photo.storage_path) > 1024 THEN
      RAISE EXCEPTION 'account_chat_photo_storage_path_invalid';
    END IF;

    IF v_photo.chat_type = 'single' THEN
      v_resource_type := 'single_session';
      v_resource_id := v_photo.session_id;
      SELECT s.user_id, s.deleted_at
        INTO v_parent_owner, v_parent_deleted_at
      FROM public.chat_sessions AS s
      WHERE s.id = v_resource_id
      FOR UPDATE;
    ELSIF v_photo.chat_type = 'group' THEN
      v_resource_type := 'group';
      v_resource_id := v_photo.group_id;
      SELECT g.owner_id, g.deleted_at
        INTO v_parent_owner, v_parent_deleted_at
      FROM public.chat_groups AS g
      WHERE g.id = v_resource_id
      FOR UPDATE;
    ELSE
      RAISE EXCEPTION 'account_chat_photo_type_invalid';
    END IF;

    IF NOT FOUND OR v_parent_owner IS DISTINCT FROM p_user_id THEN
      RAISE EXCEPTION 'account_chat_photo_parent_owner_mismatch';
    END IF;

    -- Existing soft-deleted chats keep their original deletion clock. Active
    -- account-owned chats receive the account request timestamp. Photo retention
    -- is independently fixed at 30 days even when a test environment uses a shorter
    -- account grace period; cancellation before prepare creates no cleanup jobs.
    v_deleted_at := COALESCE(v_parent_deleted_at, p_requested_at);

    INSERT INTO public.chat_deletion_jobs (
      resource_type, resource_id, owner_id, deleted_at, purge_after
    ) VALUES (
      v_resource_type, v_resource_id, p_user_id, v_deleted_at,
      v_deleted_at + interval '30 days'
    )
    ON CONFLICT (resource_type, resource_id) DO NOTHING;

    SELECT j.* INTO v_job
    FROM public.chat_deletion_jobs AS j
    WHERE j.resource_type = v_resource_type
      AND j.resource_id = v_resource_id
    FOR UPDATE;

    IF NOT FOUND OR v_job.owner_id IS DISTINCT FROM p_user_id
       OR v_job.deleted_at IS DISTINCT FROM v_deleted_at
       OR v_job.purge_after IS DISTINCT FROM v_deleted_at + interval '30 days' THEN
      RAISE EXCEPTION 'account_chat_photo_deletion_job_conflict';
    END IF;

    INSERT INTO public.chat_storage_deletion_jobs (
      deletion_job_id, bucket_id, object_path, resource_type, resource_id, owner_id
    ) VALUES (
      v_job.id, 'personax-memory-photos', v_photo.storage_path,
      v_resource_type, v_resource_id, p_user_id
    )
    ON CONFLICT (bucket_id, object_path) DO NOTHING;

    SELECT sj.* INTO v_storage_job
    FROM public.chat_storage_deletion_jobs AS sj
    WHERE sj.bucket_id = 'personax-memory-photos'
      AND sj.object_path = v_photo.storage_path
    FOR UPDATE;

    IF NOT FOUND OR v_storage_job.deletion_job_id IS DISTINCT FROM v_job.id
       OR v_storage_job.resource_type IS DISTINCT FROM v_resource_type
       OR v_storage_job.resource_id IS DISTINCT FROM v_resource_id
       OR v_storage_job.owner_id IS DISTINCT FROM p_user_id THEN
      RAISE EXCEPTION 'account_chat_photo_storage_job_conflict';
    END IF;

    v_queued := v_queued + 1;
  END LOOP;

  RETURN v_queued;
END;
$function$;

REVOKE ALL ON FUNCTION private.enqueue_account_chat_memory_photo_cleanup(uuid, timestamptz, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.enqueue_account_chat_memory_photo_cleanup(uuid, timestamptz, timestamptz)
  TO postgres;

-- Group chat charges are independent financial/idempotency evidence. The
-- group parent and auth user both cascade to these rows, so archive them first.
-- Group turn request_content is transcript content: retain only the minimal
-- idempotency metadata, never the player's message text.
ALTER TABLE public.account_deletion_archive_items
  DROP CONSTRAINT IF EXISTS account_deletion_archive_items_source_table_check;
ALTER TABLE public.account_deletion_archive_items
  ADD CONSTRAINT account_deletion_archive_items_source_table_check
  CHECK (source_table IN (
    'ai_generation_records',
    'wallet_transactions',
    'chat_turn_charges',
    'chat_turn_events',
    'chat_group_turn_charges',
    'chat_group_turns'
  ));

CREATE OR REPLACE FUNCTION public.prepare_account_deletion(p_user_id uuid)
 RETURNS TABLE(batch_id uuid, target_user_id uuid, batch_status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_requested_at timestamptz;
  v_scheduled_for timestamptz;
  v_batch_id uuid;
  v_status text;
  v_ai_source bigint;
  v_ai_archived bigint;
  v_wallet_source bigint;
  v_wallet_archived bigint;
  v_charge_source bigint;
  v_charge_archived bigint;
  v_event_source bigint;
  v_event_archived bigint;
  v_group_charge_source bigint;
  v_group_charge_archived bigint;
  v_group_turn_source bigint;
  v_group_turn_archived bigint;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION '目標帳號不可為空';
  END IF;

  SELECT r.requested_at, r.scheduled_for
    INTO v_requested_at, v_scheduled_for
  FROM public.account_deletion_requests AS r
  WHERE r.user_id = p_user_id
    AND r.scheduled_for <= pg_catalog.statement_timestamp()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到此帳號已到期的刪除申請';
  END IF;

  -- Enqueue only after the recovery deadline has elapsed and this exact
  -- request row is locked. A cancellation that wins before this point leaves
  -- no photo cleanup jobs behind; queue retention ends at scheduled_for.
  PERFORM private.enqueue_account_chat_memory_photo_cleanup(
    p_user_id, v_requested_at, v_scheduled_for
  );

  -- Account deletion bypasses chat soft-delete RPCs; preserve character-use
  -- tombstones and completed assistant-turn totals before Auth FK cascades.
  -- This is idempotent and shares this transaction with all later archive steps.
  PERFORM private.snapshot_account_chat_character_history(p_user_id);

  -- Lock/reuse this exact request's batch. Never create a second active batch.
  SELECT b.id, b.status
    INTO v_batch_id, v_status
  FROM public.account_deletion_archive_batches AS b
  WHERE b.target_user_id = p_user_id
    AND b.requested_at = v_requested_at
    AND b.scheduled_for = v_scheduled_for
    AND b.status NOT IN ('completed', 'cancelled')
  ORDER BY b.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND AND v_status = 'deleting' THEN
    -- New-code deleting batches already committed character archival atomically.
    -- Heal a legacy deleting batch only if owned character rows are still present;
    -- this also keeps a retry safe after the Auth profile has already disappeared.
    IF EXISTS (
      SELECT 1 FROM public.characters AS c
      WHERE c.author_id = p_user_id
    ) THEN
      PERFORM private.archive_account_characters(p_user_id);
    END IF;
    -- The status change and relational cleanup commit in one PostgreSQL transaction.
    -- Therefore a committed deleting batch means cleanup already completed; do not
    -- compare now-empty source tables with their preserved archive row counts.
    RETURN QUERY SELECT v_batch_id, p_user_id, 'deleting'::text;
    RETURN;
  ELSIF FOUND THEN
    -- The Auth profile still exists while this branch is active. Archive all of its
    -- characters in this same transaction before marking the batch deleting.
    PERFORM private.archive_account_characters(p_user_id);

    -- Backfill billing/audit snapshots for older batches created before these source
    -- tables were added to the archive. ON CONFLICT preserves any prior payload so the
    -- exact-payload checks below still fail closed on a conflicting existing snapshot.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_charges', c.turn_id::text, pg_catalog.to_jsonb(c)
    FROM public.chat_turn_charges AS c
    WHERE c.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_events', e.event_id::text, pg_catalog.to_jsonb(e)
    FROM public.chat_turn_events AS e
    WHERE e.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turn_charges', gc.id::text, pg_catalog.to_jsonb(gc)
    FROM public.chat_group_turn_charges AS gc
    WHERE gc.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    -- Exclude request_content and user_id: this preserves retry/idempotency
    -- metadata without retaining the group player's transcript text.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turns', gt.id::text,
      pg_catalog.jsonb_build_object(
        'id', gt.id,
        'group_id', gt.group_id,
        'request_key', gt.request_key,
        'status', gt.status,
        'created_at', gt.created_at,
        'completed_at', gt.completed_at
      )
    FROM public.chat_group_turns AS gt
    WHERE gt.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    -- A failed or interrupted archive can be retried only if every remaining source row
    -- is exactly represented in the existing archive. Any mismatch fails closed.
    SELECT count(*) INTO v_ai_source
    FROM public.ai_generation_records AS a WHERE a.user_id = p_user_id;
    SELECT count(*) INTO v_wallet_source
    FROM public.wallet_transactions AS w WHERE w.user_id = p_user_id;
    SELECT count(*) INTO v_ai_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'ai_generation_records';
    SELECT count(*) INTO v_wallet_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'wallet_transactions';
    SELECT count(*) INTO v_charge_source
    FROM public.chat_turn_charges AS c WHERE c.user_id = p_user_id;
    SELECT count(*) INTO v_charge_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_charges';
    SELECT count(*) INTO v_event_source
    FROM public.chat_turn_events AS e WHERE e.user_id = p_user_id;
    SELECT count(*) INTO v_event_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_events';
    SELECT count(*) INTO v_group_charge_source
    FROM public.chat_group_turn_charges AS gc WHERE gc.user_id = p_user_id;
    SELECT count(*) INTO v_group_charge_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turn_charges';
    SELECT count(*) INTO v_group_turn_source
    FROM public.chat_group_turns AS gt WHERE gt.user_id = p_user_id;
    SELECT count(*) INTO v_group_turn_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turns';

    IF v_ai_source <> v_ai_archived OR v_wallet_source <> v_wallet_archived
       OR v_charge_source <> v_charge_archived OR v_event_source <> v_event_archived
       OR v_group_charge_source <> v_group_charge_archived
       OR v_group_turn_source <> v_group_turn_archived
       OR EXISTS (
         SELECT 1 FROM public.ai_generation_records AS a
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'ai_generation_records'
          AND i.source_record_id = a.id::text
         WHERE a.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(a))
       )
       OR EXISTS (
         SELECT 1 FROM public.wallet_transactions AS w
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'wallet_transactions'
          AND i.source_record_id = w.id::text
         WHERE w.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(w))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_turn_charges AS c
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_turn_charges'
          AND i.source_record_id = c.turn_id::text
         WHERE c.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(c))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_turn_events AS e
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_turn_events'
          AND i.source_record_id = e.event_id::text
         WHERE e.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(e))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_group_turn_charges AS gc
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_group_turn_charges'
          AND i.source_record_id = gc.id::text
         WHERE gc.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(gc))
       )
       OR EXISTS (
         SELECT 1 FROM public.chat_group_turns AS gt
         LEFT JOIN public.account_deletion_archive_items AS i
           ON i.batch_id = v_batch_id
          AND i.source_table = 'chat_group_turns'
          AND i.source_record_id = gt.id::text
         WHERE gt.user_id = p_user_id
           AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.jsonb_build_object(
             'id', gt.id,
             'group_id', gt.group_id,
             'request_key', gt.request_key,
             'status', gt.status,
             'created_at', gt.created_at,
             'completed_at', gt.completed_at
           ))
       ) THEN
      RAISE EXCEPTION '既有封存批次與來源資料不一致，已停止刪除以避免資料遺失';
    END IF;

    UPDATE public.account_deletion_archive_batches AS b
    SET status = 'archived',
        attempt_count = b.attempt_count + 1,
        started_at = pg_catalog.statement_timestamp(),
        updated_at = pg_catalog.statement_timestamp(),
        last_error = NULL
    WHERE b.id = v_batch_id;
  ELSE
    -- No existing batch: preserve/detach every character before creating the archive
    -- batch. Any later failure rolls this change back with the same transaction.
    PERFORM private.archive_account_characters(p_user_id);

    SELECT a.batch_id INTO v_batch_id
    FROM public.archive_account_deletion_data(p_user_id) AS a
    LIMIT 1;

    -- Preserve billing/audit rows as well as the original AI and wallet archive payloads.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_charges', c.turn_id::text, pg_catalog.to_jsonb(c)
    FROM public.chat_turn_charges AS c
    WHERE c.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_turn_events', e.event_id::text, pg_catalog.to_jsonb(e)
    FROM public.chat_turn_events AS e
    WHERE e.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turn_charges', gc.id::text, pg_catalog.to_jsonb(gc)
    FROM public.chat_group_turn_charges AS gc
    WHERE gc.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    -- Exclude request_content and user_id: this preserves retry/idempotency
    -- metadata without retaining the group player's transcript text.
    INSERT INTO public.account_deletion_archive_items
      (batch_id, source_table, source_record_id, payload)
    SELECT v_batch_id, 'chat_group_turns', gt.id::text,
      pg_catalog.jsonb_build_object(
        'id', gt.id,
        'group_id', gt.group_id,
        'request_key', gt.request_key,
        'status', gt.status,
        'created_at', gt.created_at,
        'completed_at', gt.completed_at
      )
    FROM public.chat_group_turns AS gt
    WHERE gt.user_id = p_user_id
    ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
    DO NOTHING;

    v_status := 'archived';
  END IF;

  -- Verify billing/audit archive rows too before any irreversible deletion.
  SELECT count(*) INTO v_charge_source
  FROM public.chat_turn_charges AS c WHERE c.user_id = p_user_id;
  SELECT count(*) INTO v_charge_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_charges';
  SELECT count(*) INTO v_event_source
  FROM public.chat_turn_events AS e WHERE e.user_id = p_user_id;
  SELECT count(*) INTO v_event_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_turn_events';
  SELECT count(*) INTO v_group_charge_source
  FROM public.chat_group_turn_charges AS gc WHERE gc.user_id = p_user_id;
  SELECT count(*) INTO v_group_charge_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turn_charges';
  SELECT count(*) INTO v_group_turn_source
  FROM public.chat_group_turns AS gt WHERE gt.user_id = p_user_id;
  SELECT count(*) INTO v_group_turn_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'chat_group_turns';

  IF v_charge_source <> v_charge_archived OR v_event_source <> v_event_archived
     OR v_group_charge_source <> v_group_charge_archived
     OR v_group_turn_source <> v_group_turn_archived
     OR EXISTS (
       SELECT 1 FROM public.chat_turn_charges AS c
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_turn_charges'
        AND i.source_record_id = c.turn_id::text
       WHERE c.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(c))
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_turn_events AS e
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_turn_events'
        AND i.source_record_id = e.event_id::text
       WHERE e.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(e))
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_group_turn_charges AS gc
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_group_turn_charges'
        AND i.source_record_id = gc.id::text
       WHERE gc.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(gc))
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_group_turns AS gt
       LEFT JOIN public.account_deletion_archive_items AS i
         ON i.batch_id = v_batch_id
        AND i.source_table = 'chat_group_turns'
        AND i.source_record_id = gt.id::text
       WHERE gt.user_id = p_user_id
         AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.jsonb_build_object(
           'id', gt.id,
           'group_id', gt.group_id,
           'request_key', gt.request_key,
           'status', gt.status,
           'created_at', gt.created_at,
           'completed_at', gt.completed_at
         ))
     ) THEN
    RAISE EXCEPTION '聊天扣款／事件紀錄封存核對失敗，已停止刪除';
  END IF;

  -- Archive verified: mark the irreversible phase before deleting source rows.
  UPDATE public.account_deletion_archive_batches AS b
  SET status = 'deleting',
      attempt_count = CASE WHEN b.attempt_count = 0 THEN 1 ELSE b.attempt_count END,
      started_at = COALESCE(b.started_at, pg_catalog.statement_timestamp()),
      updated_at = pg_catalog.statement_timestamp(),
      last_error = NULL
  WHERE b.id = v_batch_id;

  -- Remove non-cascading references before chat/profile/Auth deletion.
  DELETE FROM public.ai_generation_records WHERE user_id = p_user_id;

  -- Delete version history only for messages owned by the account being deleted.
  -- If this user edited another player's message, preserve that player's version rows
  -- and anonymize the editor reference instead of deleting someone else's history.
  DELETE FROM public.chat_message_versions AS v
  WHERE v.message_id IN (
    SELECT m.id
    FROM public.chat_messages AS m
    JOIN public.chat_sessions AS s ON s.id = m.session_id
    WHERE s.user_id = p_user_id
  );

  UPDATE public.chat_message_versions AS v
  SET edited_by = NULL
  WHERE v.edited_by = p_user_id
    AND NOT EXISTS (
      SELECT 1
      FROM public.chat_messages AS m
      JOIN public.chat_sessions AS s ON s.id = m.session_id
      WHERE m.id = v.message_id
        AND s.user_id = p_user_id
    );

  -- user_message_id uses ON DELETE RESTRICT, so charges must be removed before messages.
  DELETE FROM public.chat_turn_charges WHERE user_id = p_user_id;

  DELETE FROM public.wallet_transactions WHERE user_id = p_user_id;

  -- Old conversation schema and role/chat data are owned by the profile; their declared
  -- CASCADE relationships remove stories, private info, conversations/messages and sessions.
  -- Explicitly remove conversations first so the cleanup is clear and retry-safe.
  DELETE FROM public.conversations WHERE user_id = p_user_id;

  RETURN QUERY SELECT v_batch_id, p_user_id, 'deleting'::text;
END;
$function$;
