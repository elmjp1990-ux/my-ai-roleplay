-- The grace period is configured per Supabase environment.
-- Intentionally do not seed a duration here: set 5 minutes in test and 30 days in production
-- after applying this migration. Example environment values: test = interval '5 minutes'; production = interval '30 days'.
-- The request function fails closed until configured.
CREATE TABLE IF NOT EXISTS public.account_deletion_settings (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  grace_period interval NOT NULL
    CHECK (grace_period > interval '0 seconds' AND grace_period <= interval '365 days'),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

ALTER TABLE public.account_deletion_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.account_deletion_settings FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.request_account_deletion()
RETURNS TABLE(requested_at timestamptz, scheduled_for timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_grace_period interval;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION '請先登入';
  END IF;

  SELECT s.grace_period
    INTO v_grace_period
  FROM public.account_deletion_settings AS s
  WHERE s.singleton = true;

  IF NOT FOUND OR v_grace_period IS NULL THEN
    RAISE EXCEPTION '帳號刪除期限尚未完成環境設定，請聯絡管理員';
  END IF;

  INSERT INTO public.account_deletion_requests (user_id, scheduled_for)
  VALUES (v_user_id, pg_catalog.statement_timestamp() + v_grace_period)
  ON CONFLICT (user_id) DO NOTHING;

  RETURN QUERY
  SELECT r.requested_at, r.scheduled_for
  FROM public.account_deletion_requests AS r
  WHERE r.user_id = v_user_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.request_account_deletion() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_account_deletion() TO authenticated;
