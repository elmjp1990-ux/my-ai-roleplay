-- DRAFT ONLY — account deletion worker durable lease/fencing protocol.
-- Never apply this file to hosted Supabase. Replay only in the disposable schema CI fixture.
-- A production migration must be generated/reconciled separately after the missing
-- historical profiles/characters baseline is addressed by the approved current-state rollout.

CREATE TABLE IF NOT EXISTS public.account_deletion_work_leases (
  target_user_id uuid PRIMARY KEY,
  requested_at timestamptz NOT NULL,
  scheduled_for timestamptz NOT NULL,
  lease_token uuid NOT NULL,
  lease_generation bigint NOT NULL DEFAULT 1 CHECK (lease_generation > 0),
  lease_expires_at timestamptz NOT NULL,
  lease_status text NOT NULL CHECK (lease_status IN ('claimed', 'completed', 'cancelled')),
  batch_id uuid,
  claimed_at timestamptz NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  last_error text
);

COMMENT ON TABLE public.account_deletion_work_leases IS
  'Durable service-only account deletion worker lease. Intentionally has no Auth/request FK so recovery survives profile/Auth cascades.';

ALTER TABLE public.account_deletion_work_leases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.account_deletion_work_leases FROM PUBLIC, anon, authenticated, service_role;

-- One invocation claims one account. Ten minutes is a provisional bounded lease;
-- keep the limit at one until local phase-duration telemetry supports a different value.
-- Renew is required immediately before every external Auth Admin call and finalization.
CREATE OR REPLACE FUNCTION public.claim_account_deletion_work_items(p_limit integer DEFAULT 1)
RETURNS TABLE(
  target_user_id uuid,
  batch_id uuid,
  scheduled_for timestamptz,
  work_status text,
  lease_token uuid,
  lease_generation bigint,
  lease_expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_request record;
  v_batch record;
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_id uuid;
  v_active_count integer;
  v_claimed integer := 0;
  v_now timestamptz := pg_catalog.statement_timestamp();
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'invalid_account_deletion_claim_limit' USING ERRCODE = '22023';
  END IF;

  -- Due requests: lock request first, then lease, then any archive batch.
  FOR v_request IN
    SELECT q.user_id, q.requested_at, q.scheduled_for
    FROM public.account_deletion_requests AS q
    WHERE q.scheduled_for <= v_now
    ORDER BY q.scheduled_for, q.user_id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_batch_id := NULL;
    SELECT pg_catalog.count(*)::integer
      INTO v_active_count
    FROM public.account_deletion_archive_batches AS b
    WHERE b.target_user_id = v_request.user_id
      AND b.requested_at = v_request.requested_at
      AND b.scheduled_for = v_request.scheduled_for
      AND b.status IN ('pending', 'archiving', 'archived', 'deleting');

    IF v_active_count > 1 THEN
      RAISE EXCEPTION 'duplicate_active_account_deletion_batches';
    END IF;

    INSERT INTO public.account_deletion_work_leases (
      target_user_id, requested_at, scheduled_for, lease_token,
      lease_generation, lease_expires_at, lease_status, batch_id
    ) VALUES (
      v_request.user_id, v_request.requested_at, v_request.scheduled_for,
      pg_catalog.gen_random_uuid(), 1, v_now + interval '10 minutes',
      'claimed', NULL
    )
    ON CONFLICT (target_user_id) DO NOTHING;

    SELECT l.* INTO v_lease
    FROM public.account_deletion_work_leases AS l
    WHERE l.target_user_id = v_request.user_id
    FOR UPDATE SKIP LOCKED;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;
    IF v_lease.requested_at IS DISTINCT FROM v_request.requested_at
       OR v_lease.scheduled_for IS DISTINCT FROM v_request.scheduled_for THEN
      IF v_lease.lease_status <> 'cancelled' THEN
        CONTINUE;
      END IF;
      UPDATE public.account_deletion_work_leases AS l
      SET requested_at = v_request.requested_at,
          scheduled_for = v_request.scheduled_for,
          lease_token = pg_catalog.gen_random_uuid(),
          lease_generation = l.lease_generation + 1,
          lease_expires_at = v_now + interval '10 minutes',
          lease_status = 'claimed',
          batch_id = v_batch_id,
          claimed_at = v_now,
          updated_at = v_now,
          attempt_count = 0,
          last_error = NULL
      WHERE l.target_user_id = v_request.user_id
      RETURNING l.* INTO v_lease;
    ELSE
      IF v_lease.lease_status = 'completed'
         OR (v_lease.lease_status = 'claimed' AND v_lease.lease_expires_at > v_now) THEN
        CONTINUE;
      END IF;
      UPDATE public.account_deletion_work_leases AS l
      SET lease_token = pg_catalog.gen_random_uuid(),
          lease_generation = l.lease_generation + 1,
          lease_expires_at = v_now + interval '10 minutes',
          lease_status = 'claimed',
          batch_id = COALESCE(v_batch_id, l.batch_id),
          claimed_at = v_now,
          updated_at = v_now,
          last_error = NULL
      WHERE l.target_user_id = v_request.user_id
      RETURNING l.* INTO v_lease;
    END IF;

    -- The request lock and lease lock are held before taking the batch lock.
    SELECT b.id INTO v_batch_id
    FROM public.account_deletion_archive_batches AS b
    WHERE b.target_user_id = v_request.user_id
      AND b.requested_at = v_request.requested_at
      AND b.scheduled_for = v_request.scheduled_for
      AND b.status NOT IN ('completed', 'cancelled')
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_batch_id IS NOT NULL THEN
      UPDATE public.account_deletion_work_leases AS l
      SET batch_id = v_batch_id, updated_at = v_now
      WHERE l.target_user_id = v_request.user_id
        AND l.lease_token = v_lease.lease_token
        AND l.lease_generation = v_lease.lease_generation;
    END IF;

    target_user_id := v_request.user_id;
    batch_id := v_batch_id;
    scheduled_for := v_request.scheduled_for;
    work_status := CASE WHEN v_batch_id IS NULL THEN 'due' ELSE 'archived' END;
    lease_token := v_lease.lease_token;
    lease_generation := v_lease.lease_generation;
    lease_expires_at := v_lease.lease_expires_at;
    RETURN NEXT;
    v_claimed := v_claimed + 1;
  END LOOP;

  -- Recover committed deleting batches whose request row was removed by prepare.
  -- The lease row is intentionally independent of Auth and request FKs.
  IF v_claimed < p_limit THEN
    FOR v_batch IN
      SELECT b.id, b.target_user_id, b.requested_at, b.scheduled_for
      FROM public.account_deletion_archive_batches AS b
      WHERE b.status = 'deleting'
        AND b.target_user_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.account_deletion_requests AS q
          WHERE q.user_id = b.target_user_id
            AND q.requested_at = b.requested_at
            AND q.scheduled_for = b.scheduled_for
        )
      ORDER BY b.updated_at, b.id
      LIMIT (p_limit - v_claimed)
    LOOP
      INSERT INTO public.account_deletion_work_leases (
        target_user_id, requested_at, scheduled_for, lease_token,
        lease_generation, lease_expires_at, lease_status, batch_id
      ) VALUES (
        v_batch.target_user_id, v_batch.requested_at, v_batch.scheduled_for,
        pg_catalog.gen_random_uuid(), 1, v_now + interval '10 minutes',
        'claimed', v_batch.id
      )
      ON CONFLICT (target_user_id) DO NOTHING;

      SELECT l.* INTO v_lease
      FROM public.account_deletion_work_leases AS l
      WHERE l.target_user_id = v_batch.target_user_id
      FOR UPDATE SKIP LOCKED;

      IF NOT FOUND THEN
        CONTINUE;
      END IF;
      IF v_lease.requested_at IS DISTINCT FROM v_batch.requested_at
         OR v_lease.scheduled_for IS DISTINCT FROM v_batch.scheduled_for THEN
        CONTINUE;
      END IF;
      IF v_lease.lease_status = 'completed'
         OR (v_lease.lease_status = 'claimed' AND v_lease.lease_expires_at > v_now) THEN
        CONTINUE;
      END IF;

      -- Recovery lock order is lease -> batch because the request row no longer exists.
      PERFORM 1
      FROM public.account_deletion_archive_batches AS b
      WHERE b.id = v_batch.id
        AND b.status = 'deleting'
      FOR UPDATE SKIP LOCKED;
      IF NOT FOUND THEN
        CONTINUE;
      END IF;

      UPDATE public.account_deletion_work_leases AS l
      SET lease_token = pg_catalog.gen_random_uuid(),
          lease_generation = l.lease_generation + 1,
          lease_expires_at = v_now + interval '10 minutes',
          lease_status = 'claimed',
          batch_id = v_batch.id,
          claimed_at = v_now,
          updated_at = v_now,
          last_error = NULL
      WHERE l.target_user_id = v_batch.target_user_id
      RETURNING l.* INTO v_lease;

      target_user_id := v_batch.target_user_id;
      batch_id := v_batch.id;
      scheduled_for := v_batch.scheduled_for;
      work_status := 'deleting';
      lease_token := v_lease.lease_token;
      lease_generation := v_lease.lease_generation;
      lease_expires_at := v_lease.lease_expires_at;
      RETURN NEXT;
      v_claimed := v_claimed + 1;
    END LOOP;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.renew_account_deletion_lease(
  p_user_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  UPDATE public.account_deletion_work_leases AS l
  SET lease_expires_at = pg_catalog.statement_timestamp() + interval '10 minutes',
      updated_at = pg_catalog.statement_timestamp()
  WHERE l.target_user_id = p_user_id
    AND l.lease_token = p_lease_token
    AND l.lease_generation = p_lease_generation
    AND l.lease_status = 'claimed'
    AND l.lease_expires_at > pg_catalog.statement_timestamp();
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.prepare_account_deletion_leased(
  p_user_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint
)
RETURNS TABLE(batch_id uuid, target_user_id uuid, batch_status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_requested_at timestamptz;
  v_scheduled_for timestamptz;
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_id uuid;
  v_batch_status text;
BEGIN
  -- Canonical lock order: request -> lease -> batch.
  SELECT q.requested_at, q.scheduled_for
    INTO v_requested_at, v_scheduled_for
  FROM public.account_deletion_requests AS q
  WHERE q.user_id = p_user_id
    AND q.scheduled_for <= pg_catalog.statement_timestamp()
  FOR UPDATE;

  IF FOUND THEN
    SELECT l.* INTO v_lease
    FROM public.account_deletion_work_leases AS l
    WHERE l.target_user_id = p_user_id
    FOR UPDATE;
    IF NOT FOUND OR v_lease.requested_at IS DISTINCT FROM v_requested_at
       OR v_lease.scheduled_for IS DISTINCT FROM v_scheduled_for
       OR v_lease.lease_token IS DISTINCT FROM p_lease_token
       OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
       OR v_lease.lease_status <> 'claimed'
       OR v_lease.lease_expires_at <= pg_catalog.statement_timestamp() THEN
      RAISE EXCEPTION 'account_deletion_lease_lost' USING ERRCODE = '55000';
    END IF;

    SELECT b.id INTO v_batch_id
    FROM public.account_deletion_archive_batches AS b
    WHERE b.target_user_id = p_user_id
      AND b.requested_at = v_requested_at
      AND b.scheduled_for = v_scheduled_for
      AND b.status NOT IN ('completed', 'cancelled')
    ORDER BY b.created_at DESC
    LIMIT 1
    FOR UPDATE;

    -- This existing SECURITY DEFINER routine performs the verified archive and
    -- relational prepare in one transaction. Its direct service_role EXECUTE is
    -- revoked below; only this fenced wrapper remains callable by the worker.
    RETURN QUERY
      SELECT p.batch_id, p.target_user_id, p.batch_status
      FROM public.prepare_account_deletion(p_user_id) AS p;
    UPDATE public.account_deletion_work_leases AS l
    SET batch_id = (SELECT b.id FROM public.account_deletion_archive_batches AS b
                    WHERE b.target_user_id = p_user_id
                      AND b.requested_at = v_requested_at
                      AND b.scheduled_for = v_scheduled_for
                    ORDER BY b.created_at DESC LIMIT 1),
        updated_at = pg_catalog.statement_timestamp()
    WHERE l.target_user_id = p_user_id
      AND l.lease_token = p_lease_token
      AND l.lease_generation = p_lease_generation;
    RETURN;
  END IF;

  -- Recovery after prepare committed and cascaded the request row.
  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND OR v_lease.lease_token IS DISTINCT FROM p_lease_token
     OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
     OR v_lease.lease_status <> 'claimed'
     OR v_lease.lease_expires_at <= pg_catalog.statement_timestamp()
     OR v_lease.batch_id IS NULL THEN
    RAISE EXCEPTION 'account_deletion_lease_lost' USING ERRCODE = '55000';
  END IF;

  SELECT b.id, b.status INTO v_batch_id, v_batch_status
  FROM public.account_deletion_archive_batches AS b
  WHERE b.id = v_lease.batch_id
    AND b.target_user_id = p_user_id
    AND b.requested_at = v_lease.requested_at
    AND b.scheduled_for = v_lease.scheduled_for
  FOR UPDATE;

  IF NOT FOUND OR v_batch_status NOT IN ('deleting', 'completed') THEN
    RAISE EXCEPTION 'account_deletion_recovery_batch_not_ready';
  END IF;
  RETURN QUERY SELECT v_batch_id, p_user_id, v_batch_status;
END;
$function$;

CREATE OR REPLACE FUNCTION public.finalize_account_deletion_leased(
  p_user_id uuid,
  p_batch_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_user uuid;
BEGIN
  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND OR v_lease.lease_token IS DISTINCT FROM p_lease_token
     OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
     OR v_lease.lease_status <> 'claimed'
     OR v_lease.lease_expires_at <= pg_catalog.statement_timestamp()
     OR v_lease.batch_id IS DISTINCT FROM p_batch_id THEN
    RAISE EXCEPTION 'account_deletion_lease_lost' USING ERRCODE = '55000';
  END IF;

  SELECT b.target_user_id INTO v_batch_user
  FROM public.account_deletion_archive_batches AS b
  WHERE b.id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND OR v_batch_user IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'account_deletion_batch_lease_mismatch';
  END IF;

  IF NOT public.finalize_account_deletion(p_batch_id) THEN
    RETURN false;
  END IF;

  UPDATE public.account_deletion_work_leases AS l
  SET lease_status = 'completed',
      lease_expires_at = pg_catalog.statement_timestamp(),
      updated_at = pg_catalog.statement_timestamp(),
      last_error = NULL
  WHERE l.target_user_id = p_user_id
    AND l.lease_token = p_lease_token
    AND l.lease_generation = p_lease_generation;
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_account_deletion_failure_leased(
  p_user_id uuid,
  p_batch_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_lease public.account_deletion_work_leases%ROWTYPE;
BEGIN
  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND OR v_lease.lease_token IS DISTINCT FROM p_lease_token
     OR v_lease.lease_generation IS DISTINCT FROM p_lease_generation
     OR v_lease.lease_status <> 'claimed'
     OR v_lease.lease_expires_at <= pg_catalog.statement_timestamp()
     OR (p_batch_id IS NOT NULL AND v_lease.batch_id IS DISTINCT FROM p_batch_id) THEN
    RETURN false;
  END IF;

  UPDATE public.account_deletion_work_leases AS l
  SET attempt_count = l.attempt_count + 1,
      last_error = pg_catalog.left(
        coalesce(nullif(p_error_code, ''), 'worker_error'), 300
      ),
      updated_at = pg_catalog.statement_timestamp()
  WHERE l.target_user_id = p_user_id
    AND l.lease_token = p_lease_token
    AND l.lease_generation = p_lease_generation;

  IF p_batch_id IS NOT NULL THEN
    UPDATE public.account_deletion_archive_batches AS b
    SET last_error = pg_catalog.left(
          coalesce(nullif(p_error_code, ''), 'worker_error'), 300
        ),
        updated_at = pg_catalog.statement_timestamp(),
        attempt_count = b.attempt_count + 1
    WHERE b.id = p_batch_id
      AND b.target_user_id = p_user_id
      AND b.status IN ('archived', 'deleting', 'failed');
  END IF;
  RETURN true;
END;
$function$;

-- Cancellation serializes with claim using request -> lease -> batch lock order.
CREATE OR REPLACE FUNCTION public.cancel_account_deletion()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_requested_at timestamptz;
  v_scheduled_for timestamptz;
  v_now timestamptz := pg_catalog.statement_timestamp();
  v_lease public.account_deletion_work_leases%ROWTYPE;
  v_batch_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION '請先登入';
  END IF;

  SELECT r.requested_at, r.scheduled_for
    INTO v_requested_at, v_scheduled_for
  FROM public.account_deletion_requests AS r
  WHERE r.user_id = v_user_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到待處理的刪除申請';
  END IF;

  SELECT l.* INTO v_lease
  FROM public.account_deletion_work_leases AS l
  WHERE l.target_user_id = v_user_id
  FOR UPDATE;

  IF FOUND AND v_lease.requested_at = v_requested_at
     AND v_lease.scheduled_for = v_scheduled_for
     AND v_lease.lease_status = 'claimed'
     AND v_lease.lease_expires_at > v_now THEN
    RAISE EXCEPTION '刪除處理已由背景工作領取，無法取消';
  END IF;

  SELECT b.id INTO v_batch_id
  FROM public.account_deletion_archive_batches AS b
  WHERE b.target_user_id = v_user_id
    AND b.requested_at = v_requested_at
    AND b.scheduled_for = v_scheduled_for
  ORDER BY b.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    RAISE EXCEPTION '刪除處理已開始，無法透過此功能復原；請交由管理程序檢查';
  END IF;

  DELETE FROM public.account_deletion_requests AS r
  WHERE r.user_id = v_user_id
    AND r.requested_at = v_requested_at
    AND r.scheduled_for = v_scheduled_for;
  IF NOT FOUND THEN
    RAISE EXCEPTION '刪除申請狀態已變更，請重新查詢帳號狀態';
  END IF;

  IF v_lease.target_user_id IS NOT NULL THEN
    UPDATE public.account_deletion_work_leases AS l
    SET lease_status = 'cancelled',
        lease_expires_at = v_now,
        updated_at = v_now,
        last_error = NULL
    WHERE l.target_user_id = v_user_id
      AND l.requested_at = v_requested_at
      AND l.scheduled_for = v_scheduled_for;
  END IF;
END;
$function$;

-- Remove all un-fenced service-role entry points. The SECURITY DEFINER wrappers
-- above call the original routines as their owner (postgres) within one transaction.
REVOKE ALL ON FUNCTION public.get_account_deletion_work_items() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.archive_account_deletion_data(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.prepare_account_deletion(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finalize_account_deletion(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_account_deletion_failure(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.claim_account_deletion_work_items(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.renew_account_deletion_lease(uuid, uuid, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prepare_account_deletion_leased(uuid, uuid, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_account_deletion_leased(uuid, uuid, uuid, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_account_deletion_failure_leased(uuid, uuid, uuid, bigint, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.claim_account_deletion_work_items(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.renew_account_deletion_lease(uuid, uuid, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.prepare_account_deletion_leased(uuid, uuid, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_account_deletion_leased(uuid, uuid, uuid, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_account_deletion_failure_leased(uuid, uuid, uuid, bigint, text) TO service_role;

-- Keep the player-facing cancellation RPC authenticated-only.
REVOKE ALL ON FUNCTION public.cancel_account_deletion() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_account_deletion() TO authenticated;
