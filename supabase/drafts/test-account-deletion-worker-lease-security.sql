-- DRAFT ONLY — disposable PostgreSQL effective-privilege assertions.
-- Loaded only after account-deletion-worker-atomic-lease.sql in the isolated CI database.
DO $lease_security$
DECLARE
  v_function text;
BEGIN
  IF pg_catalog.has_table_privilege('service_role', 'public.account_deletion_work_leases', 'SELECT')
     OR pg_catalog.has_table_privilege('service_role', 'public.account_deletion_work_leases', 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.account_deletion_work_leases', 'SELECT')
     OR pg_catalog.has_table_privilege('anon', 'public.account_deletion_work_leases', 'SELECT') THEN
    RAISE EXCEPTION 'account_deletion_lease_table_must_not_be_directly_accessible';
  END IF;

  IF NOT pg_catalog.has_function_privilege('service_role', 'public.claim_account_deletion_work_items(integer)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('service_role', 'public.renew_account_deletion_lease(uuid,uuid,bigint)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('service_role', 'public.prepare_account_deletion_leased(uuid,uuid,bigint)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('service_role', 'public.finalize_account_deletion_leased(uuid,uuid,uuid,bigint)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('service_role', 'public.record_account_deletion_failure_leased(uuid,uuid,uuid,bigint,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role_must_have_all_fenced_worker_rpc_privileges';
  END IF;

  IF pg_catalog.has_function_privilege('authenticated', 'public.claim_account_deletion_work_items(integer)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.claim_account_deletion_work_items(integer)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('authenticated', 'public.prepare_account_deletion_leased(uuid,uuid,bigint)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.prepare_account_deletion_leased(uuid,uuid,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'fenced_worker_rpcs_must_be_service_role_only';
  END IF;

  IF pg_catalog.has_function_privilege('service_role', 'public.get_account_deletion_work_items()', 'EXECUTE')
     OR pg_catalog.has_function_privilege('service_role', 'public.archive_account_deletion_data(uuid)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('service_role', 'public.prepare_account_deletion(uuid)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('service_role', 'public.finalize_account_deletion(uuid)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('service_role', 'public.record_account_deletion_failure(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'legacy_unfenced_worker_rpcs_must_not_be_service_role_callable';
  END IF;

  IF NOT pg_catalog.has_function_privilege('authenticated', 'public.cancel_account_deletion()', 'EXECUTE')
     OR pg_catalog.has_function_privilege('service_role', 'public.cancel_account_deletion()', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.cancel_account_deletion()', 'EXECUTE') THEN
    RAISE EXCEPTION 'account_deletion_cancel_must_be_authenticated_only';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'account_deletion_work_leases'
      AND c.relrowsecurity IS TRUE
  ) THEN
    RAISE EXCEPTION 'account_deletion_work_lease_rls_must_be_enabled';
  END IF;

  FOREACH v_function IN ARRAY ARRAY[
    'claim_account_deletion_work_items(integer)',
    'renew_account_deletion_lease(uuid,uuid,bigint)',
    'prepare_account_deletion_leased(uuid,uuid,bigint)',
    'finalize_account_deletion_leased(uuid,uuid,uuid,bigint)',
    'record_account_deletion_failure_leased(uuid,uuid,uuid,bigint,text)',
    'cancel_account_deletion()'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc AS p
      JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.oid = pg_catalog.to_regprocedure('public.' || v_function)
        AND p.prosecdef IS TRUE
        AND p.proconfig @> ARRAY['search_path=""']
    ) THEN
      RAISE EXCEPTION 'lease_rpc_must_be_security_definer_with_empty_search_path: %', v_function;
    END IF;
  END LOOP;
END;
$lease_security$;
