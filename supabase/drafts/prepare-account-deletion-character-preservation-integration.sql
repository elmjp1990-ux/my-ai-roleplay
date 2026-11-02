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

    IF v_ai_source <> v_ai_archived OR v_wallet_source <> v_wallet_archived
       OR v_charge_source <> v_charge_archived OR v_event_source <> v_event_archived
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

  IF v_charge_source <> v_charge_archived OR v_event_source <> v_event_archived
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
$function$

