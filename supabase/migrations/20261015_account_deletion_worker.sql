-- Account deletion worker orchestration.
-- This migration is intentionally proposed in a PR only; do not apply until migration history is reconciled.

CREATE OR REPLACE FUNCTION public.get_account_deletion_work_items()
RETURNS TABLE (
  target_user_id uuid,
  batch_id uuid,
  scheduled_for timestamptz,
  work_status text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT q.user_id, b.id, q.scheduled_for, COALESCE(b.status, 'due')::text
  FROM public.account_deletion_requests AS q
  LEFT JOIN LATERAL (
    SELECT ab.id, ab.status
    FROM public.account_deletion_archive_batches AS ab
    WHERE ab.target_user_id = q.user_id
      AND ab.requested_at = q.requested_at
      AND ab.scheduled_for = q.scheduled_for
      AND ab.status NOT IN ('completed', 'cancelled')
    ORDER BY ab.created_at DESC
    LIMIT 1
  ) AS b ON true
  WHERE q.scheduled_for <= pg_catalog.statement_timestamp()
    AND NOT EXISTS (
      SELECT 1
      FROM public.account_deletion_archive_batches AS completed_batch
      WHERE completed_batch.target_user_id = q.user_id
        AND completed_batch.requested_at = q.requested_at
        AND completed_batch.scheduled_for = q.scheduled_for
        AND completed_batch.status = 'completed'
    )

  UNION ALL

  SELECT b.target_user_id, b.id, b.scheduled_for, b.status
  FROM public.account_deletion_archive_batches AS b
  WHERE b.status = 'deleting'
    AND b.target_user_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.account_deletion_requests AS q
      WHERE q.user_id = b.target_user_id
        AND q.requested_at = b.requested_at
        AND q.scheduled_for = b.scheduled_for
    );
$function$;

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
    -- The status change and relational cleanup commit in one PostgreSQL transaction.
    -- Therefore a committed deleting batch means cleanup already completed; do not
    -- compare now-empty source tables with their preserved archive row counts.
    RETURN QUERY SELECT v_batch_id, p_user_id, 'deleting'::text;
    RETURN;
  ELSIF FOUND THEN
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

  DELETE FROM public.chat_message_versions AS v
  WHERE v.edited_by = p_user_id
     OR v.message_id IN (
       SELECT m.id
       FROM public.chat_messages AS m
       JOIN public.chat_sessions AS s ON s.id = m.session_id
       WHERE s.user_id = p_user_id
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

CREATE OR REPLACE FUNCTION public.finalize_account_deletion(p_batch_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_status text;
  v_user_id uuid;
BEGIN
  IF p_batch_id IS NULL THEN
    RAISE EXCEPTION '封存批次不可為空';
  END IF;

  SELECT b.status, b.target_user_id
    INTO v_status, v_user_id
  FROM public.account_deletion_archive_batches AS b
  WHERE b.id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到封存批次';
  END IF;

  IF v_status = 'completed' THEN
    RETURN true;
  END IF;

  IF v_status <> 'deleting' THEN
    RAISE EXCEPTION '批次尚未進入 deleting 狀態';
  END IF;

  IF EXISTS (SELECT 1 FROM auth.users AS u WHERE u.id = v_user_id) THEN
    RAISE EXCEPTION 'Auth 帳號仍存在，不能標記刪除完成';
  END IF;

  UPDATE public.account_deletion_archive_batches
  SET status = 'completed',
      completed_at = pg_catalog.statement_timestamp(),
      updated_at = pg_catalog.statement_timestamp(),
      last_error = NULL
  WHERE id = p_batch_id;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_account_deletion_failure(
  p_batch_id uuid,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF p_batch_id IS NULL THEN
    RETURN false;
  END IF;

  UPDATE public.account_deletion_archive_batches
  SET last_error = left(COALESCE(NULLIF(p_error_code, ''), 'worker_error'), 300),
      updated_at = pg_catalog.statement_timestamp(),
      attempt_count = attempt_count + 1
  WHERE id = p_batch_id
    AND status IN ('archived', 'deleting', 'failed');

  RETURN FOUND;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_account_deletion_work_items() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prepare_account_deletion(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_account_deletion(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_account_deletion_failure(uuid, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_account_deletion_work_items() TO service_role;
GRANT EXECUTE ON FUNCTION public.prepare_account_deletion(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_account_deletion(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_account_deletion_failure(uuid, text) TO service_role;
