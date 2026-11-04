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
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION '請先登入';
  END IF;

  -- Lock the request so recovery cannot race with a worker starting the same request.
  SELECT r.requested_at, r.scheduled_for
    INTO v_requested_at, v_scheduled_for
  FROM public.account_deletion_requests AS r
  WHERE r.user_id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到待處理的刪除申請';
  END IF;

  -- Before the deadline, normal cancellation is allowed.
  -- After the deadline, recovery is allowed only if no archive/deletion batch
  -- has been created for this exact request. Once processing has started,
  -- manual recovery is blocked to avoid racing with deletion.
  IF v_scheduled_for <= v_now AND EXISTS (
    SELECT 1
    FROM public.account_deletion_archive_batches AS b
    WHERE b.target_user_id = v_user_id
      AND b.requested_at = v_requested_at
      AND b.scheduled_for = v_scheduled_for
  ) THEN
    RAISE EXCEPTION '刪除處理已開始，無法透過此功能復原；請交由管理程序檢查';
  END IF;

  DELETE FROM public.account_deletion_requests AS r
  WHERE r.user_id = v_user_id
    AND r.requested_at = v_requested_at
    AND r.scheduled_for = v_scheduled_for;

  IF NOT FOUND THEN
    RAISE EXCEPTION '刪除申請狀態已變更，請重新查詢帳號狀態';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.cancel_account_deletion() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_account_deletion() TO authenticated, postgres;