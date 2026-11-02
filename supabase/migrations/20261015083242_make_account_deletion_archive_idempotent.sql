CREATE OR REPLACE FUNCTION public.archive_account_deletion_data(p_user_id uuid)
RETURNS TABLE(
  batch_id uuid,
  target_user_id uuid,
  ai_source_rows bigint,
  ai_archived_rows bigint,
  wallet_source_rows bigint,
  wallet_archived_rows bigint,
  batch_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_requested_at timestamptz;
  v_scheduled_for timestamptz;
  v_batch_id uuid;
  v_ai_source bigint;
  v_ai_archived bigint;
  v_wallet_source bigint;
  v_wallet_archived bigint;
  v_existing_status text;
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

  -- Reuse a verified archive instead of creating duplicate batches on retries.
  SELECT b.id, b.status
    INTO v_batch_id, v_existing_status
  FROM public.account_deletion_archive_batches AS b
  WHERE b.target_user_id = p_user_id
    AND b.requested_at = v_requested_at
    AND b.scheduled_for = v_scheduled_for
    AND b.status IN ('archived', 'deleting', 'completed')
  ORDER BY b.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    SELECT pg_catalog.count(*) INTO v_ai_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id
      AND i.source_table = 'ai_generation_records';

    SELECT pg_catalog.count(*) INTO v_wallet_archived
    FROM public.account_deletion_archive_items AS i
    WHERE i.batch_id = v_batch_id
      AND i.source_table = 'wallet_transactions';

    SELECT pg_catalog.count(*) INTO v_ai_source
    FROM public.ai_generation_records AS a
    WHERE a.user_id = p_user_id;

    SELECT pg_catalog.count(*) INTO v_wallet_source
    FROM public.wallet_transactions AS w
    WHERE w.user_id = p_user_id;

    RETURN QUERY SELECT v_batch_id, p_user_id, v_ai_source, v_ai_archived,
      v_wallet_source, v_wallet_archived, v_existing_status;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.account_deletion_archive_batches AS b
    WHERE b.target_user_id = p_user_id
      AND b.status IN ('pending', 'archiving', 'deleting')
  ) THEN
    RAISE EXCEPTION '此帳號已有正在處理的封存／刪除批次';
  END IF;

  INSERT INTO public.account_deletion_archive_batches (
    target_user_id, status, requested_at, scheduled_for, started_at,
    attempt_count, last_error
  )
  VALUES (
    p_user_id, 'archiving', v_requested_at, v_scheduled_for,
    pg_catalog.statement_timestamp(), 1, NULL
  )
  RETURNING id INTO v_batch_id;

  SELECT pg_catalog.count(*) INTO v_ai_source
  FROM public.ai_generation_records AS a
  WHERE a.user_id = p_user_id;

  SELECT pg_catalog.count(*) INTO v_wallet_source
  FROM public.wallet_transactions AS w
  WHERE w.user_id = p_user_id;

  INSERT INTO public.account_deletion_archive_items AS dst (
    batch_id, source_table, source_record_id, payload
  )
  SELECT v_batch_id, 'ai_generation_records', a.id::text, pg_catalog.to_jsonb(a)
  FROM public.ai_generation_records AS a
  WHERE a.user_id = p_user_id
  ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
  DO NOTHING;

  INSERT INTO public.account_deletion_archive_items AS dst (
    batch_id, source_table, source_record_id, payload
  )
  SELECT v_batch_id, 'wallet_transactions', w.id::text, pg_catalog.to_jsonb(w)
  FROM public.wallet_transactions AS w
  WHERE w.user_id = p_user_id
  ON CONFLICT ON CONSTRAINT account_deletion_archive_item_batch_id_source_table_source__key
  DO NOTHING;

  SELECT pg_catalog.count(*) INTO v_ai_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'ai_generation_records';

  SELECT pg_catalog.count(*) INTO v_wallet_archived
  FROM public.account_deletion_archive_items AS i
  WHERE i.batch_id = v_batch_id AND i.source_table = 'wallet_transactions';

  IF v_ai_source <> v_ai_archived OR v_wallet_source <> v_wallet_archived THEN
    RAISE EXCEPTION '封存筆數不一致，已取消本次交易';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.ai_generation_records AS a
    LEFT JOIN public.account_deletion_archive_items AS i
      ON i.batch_id = v_batch_id
     AND i.source_table = 'ai_generation_records'
     AND i.source_record_id = a.id::text
    WHERE a.user_id = p_user_id
      AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(a))
  ) THEN
    RAISE EXCEPTION 'AI 原始生成紀錄內容核對失敗';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.wallet_transactions AS w
    LEFT JOIN public.account_deletion_archive_items AS i
      ON i.batch_id = v_batch_id
     AND i.source_table = 'wallet_transactions'
     AND i.source_record_id = w.id::text
    WHERE w.user_id = p_user_id
      AND (i.id IS NULL OR i.payload IS DISTINCT FROM pg_catalog.to_jsonb(w))
  ) THEN
    RAISE EXCEPTION '錢包交易紀錄核對失敗';
  END IF;

  UPDATE public.account_deletion_archive_batches AS b
  SET status = 'archived',
      updated_at = pg_catalog.statement_timestamp(),
      last_error = NULL
  WHERE b.id = v_batch_id;

  RETURN QUERY SELECT v_batch_id, p_user_id, v_ai_source, v_ai_archived,
    v_wallet_source, v_wallet_archived, 'archived'::text;
END;
$function$;