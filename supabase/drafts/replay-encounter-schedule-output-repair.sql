BEGIN;

DO $$
DECLARE
  v_rls boolean;
BEGIN
  SELECT c.relrowsecurity INTO v_rls
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'encounter_schedule_generation_outputs';

  IF v_rls IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'encounter_schedule_generation_outputs_rls_not_enabled';
  END IF;

  SELECT c.relrowsecurity INTO v_rls
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'encounter_schedule_generation_output_revisions';

  IF v_rls IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'encounter_schedule_generation_output_revisions_rls_not_enabled';
  END IF;

  IF has_table_privilege('anon', 'public.encounter_schedule_generation_outputs', 'SELECT')
     OR has_table_privilege('authenticated', 'public.encounter_schedule_generation_outputs', 'SELECT')
     OR has_table_privilege('anon', 'public.encounter_schedule_generation_output_revisions', 'SELECT')
     OR has_table_privilege('authenticated', 'public.encounter_schedule_generation_output_revisions', 'SELECT') THEN
    RAISE EXCEPTION 'encounter_schedule_private_ai_output_exposed_to_client_roles';
  END IF;

  IF NOT has_table_privilege('service_role', 'public.encounter_schedule_generation_outputs', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.encounter_schedule_generation_outputs', 'INSERT')
     OR NOT has_table_privilege('service_role', 'public.encounter_schedule_generation_output_revisions', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.encounter_schedule_generation_output_revisions', 'INSERT') THEN
    RAISE EXCEPTION 'encounter_schedule_service_role_privileges_missing';
  END IF;

  IF has_function_privilege('anon',
       'public.claim_encounter_schedule_repair(uuid,uuid,uuid,text)', 'EXECUTE')
     OR has_function_privilege('authenticated',
       'public.claim_encounter_schedule_repair(uuid,uuid,uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role',
       'public.claim_encounter_schedule_repair(uuid,uuid,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'encounter_schedule_repair_rpc_grants_invalid';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger t
    WHERE t.tgrelid = 'public.encounter_schedule_generation_outputs'::regclass
      AND t.tgname = 'encounter_schedule_raw_output_immutable'
      AND NOT t.tgisinternal
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger t
    WHERE t.tgrelid = 'public.encounter_schedule_generation_output_revisions'::regclass
      AND t.tgname = 'encounter_schedule_output_revision_immutable'
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'encounter_schedule_immutable_triggers_missing';
  END IF;
END;
$$;

ROLLBACK;
