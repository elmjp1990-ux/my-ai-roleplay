-- Read-only structural assertions for the local-only cumulative-turn draft.
-- Run only after the disposable local replay workflow applies the draft.
-- This does not replace transactional fixture tests for actual snapshot/purge behavior.

DO $verify$
DECLARE
  v_table oid := pg_catalog.to_regclass('public.chat_deletion_character_turn_stats')::oid;
  v_helper oid := pg_catalog.to_regprocedure(
    'private.snapshot_chat_deletion_character_turn_stats(text,uuid,uuid)'
  );
  v_proc oid;
  v_def text;
  v_owner text;
  v_security_definer boolean;
  v_search_path text;
BEGIN
  IF v_table IS NULL THEN
    RAISE EXCEPTION 'archive_table_missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class c
    WHERE c.oid = v_table AND c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'archive_table_rls_not_enabled';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'chat_deletion_character_turn_stats'
      AND column_name NOT IN (
        'resource_type', 'resource_id', 'character_id', 'turn_count', 'created_at'
      )
  ) THEN
    RAISE EXCEPTION 'archive_table_contains_unapproved_columns';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_deletion_character_turn_stats'
  ) THEN
    RAISE EXCEPTION 'archive_table_must_not_have_client_policies';
  END IF;

  IF pg_catalog.has_table_privilege('anon', v_table, 'SELECT')
     OR pg_catalog.has_table_privilege('anon', v_table, 'INSERT')
     OR pg_catalog.has_table_privilege('anon', v_table, 'UPDATE')
     OR pg_catalog.has_table_privilege('anon', v_table, 'DELETE')
     OR pg_catalog.has_table_privilege('anon', v_table, 'TRUNCATE')
     OR pg_catalog.has_table_privilege('authenticated', v_table, 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', v_table, 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', v_table, 'UPDATE')
     OR pg_catalog.has_table_privilege('authenticated', v_table, 'DELETE')
     OR pg_catalog.has_table_privilege('authenticated', v_table, 'TRUNCATE')
     OR pg_catalog.has_table_privilege('service_role', v_table, 'SELECT')
     OR pg_catalog.has_table_privilege('service_role', v_table, 'INSERT')
     OR pg_catalog.has_table_privilege('service_role', v_table, 'UPDATE')
     OR pg_catalog.has_table_privilege('service_role', v_table, 'DELETE')
     OR pg_catalog.has_table_privilege('service_role', v_table, 'TRUNCATE') THEN
    RAISE EXCEPTION 'archive_table_has_direct_role_grants';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND (
        pg_catalog.has_table_privilege('anon', c.oid, 'TRUNCATE')
        OR pg_catalog.has_table_privilege('authenticated', c.oid, 'TRUNCATE')
      )
  ) THEN
    RAISE EXCEPTION 'client_role_truncate_privilege_remains';
  END IF;

  IF v_helper IS NULL THEN
    RAISE EXCEPTION 'snapshot_helper_missing';
  END IF;

  SELECT pg_catalog.pg_get_userbyid(p.proowner), p.prosecdef,
         (SELECT option_value FROM pg_catalog.pg_options_to_table(p.proconfig)
          WHERE option_name = 'search_path')
    INTO v_owner, v_security_definer, v_search_path
  FROM pg_catalog.pg_proc p
  WHERE p.oid = v_helper;
  IF v_owner <> 'postgres' OR NOT v_security_definer
     OR v_search_path IS DISTINCT FROM '""' THEN
    RAISE EXCEPTION 'snapshot_helper_security_definer_owner_or_search_path_mismatch';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc p
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
    ) AS acl
    WHERE p.oid = v_helper
      AND acl.grantee = 0
      AND acl.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'snapshot_helper_public_execute_not_revoked';
  END IF;

  IF pg_catalog.has_function_privilege('anon', v_helper, 'EXECUTE')
     OR pg_catalog.has_function_privilege('authenticated', v_helper, 'EXECUTE')
     OR pg_catalog.has_function_privilege('service_role', v_helper, 'EXECUTE') THEN
    RAISE EXCEPTION 'snapshot_helper_exposed_to_client_or_service_role';
  END IF;

  FOREACH v_proc IN ARRAY ARRAY[
    pg_catalog.to_regprocedure('public.delete_chat_session_content(uuid)')::oid,
    pg_catalog.to_regprocedure('public.delete_chat_group_with_related_data(uuid)')::oid,
    pg_catalog.to_regprocedure('public.purge_chat_deletion_job(uuid)')::oid,
    pg_catalog.to_regprocedure('public.get_character_turn_counts(uuid[])')::oid,
    pg_catalog.to_regprocedure('public.get_public_character_turn_count(uuid)')::oid
  ] LOOP
    IF v_proc IS NULL THEN
      RAISE EXCEPTION 'required_rpc_missing';
    END IF;
    SELECT pg_catalog.pg_get_userbyid(p.proowner), p.prosecdef,
           (SELECT option_value FROM pg_catalog.pg_options_to_table(p.proconfig)
            WHERE option_name = 'search_path')
      INTO v_owner, v_security_definer, v_search_path
    FROM pg_catalog.pg_proc p
    WHERE p.oid = v_proc;

    IF v_owner <> 'postgres' OR NOT v_security_definer
       OR v_search_path IS DISTINCT FROM '""' THEN
      RAISE EXCEPTION 'rpc_security_definer_owner_or_search_path_mismatch: %', v_proc::regprocedure;
    END IF;
    IF EXISTS (
      SELECT 1
      FROM pg_catalog.pg_proc p
      CROSS JOIN LATERAL pg_catalog.aclexplode(
        COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
      ) AS acl
      WHERE p.oid = v_proc
        AND acl.grantee = 0
        AND acl.privilege_type = 'EXECUTE'
    ) THEN
      RAISE EXCEPTION 'rpc_public_execute_not_revoked: %', v_proc::regprocedure;
    END IF;
  END LOOP;

  v_proc := pg_catalog.to_regprocedure('public.delete_chat_session_content(uuid)');
  v_def := pg_catalog.pg_get_functiondef(v_proc);
  IF pg_catalog.strpos(v_def, 'snapshot_chat_deletion_character_turn_stats') = 0
     OR NOT pg_catalog.has_function_privilege('authenticated', v_proc, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('service_role', v_proc, 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', v_proc, 'EXECUTE') THEN
    RAISE EXCEPTION 'single_delete_rpc_snapshot_or_acl_mismatch';
  END IF;

  v_proc := pg_catalog.to_regprocedure('public.delete_chat_group_with_related_data(uuid)');
  v_def := pg_catalog.pg_get_functiondef(v_proc);
  IF pg_catalog.strpos(v_def, 'snapshot_chat_deletion_character_turn_stats') = 0
     OR NOT pg_catalog.has_function_privilege('authenticated', v_proc, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('service_role', v_proc, 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', v_proc, 'EXECUTE') THEN
    RAISE EXCEPTION 'group_delete_rpc_snapshot_or_acl_mismatch';
  END IF;

  v_proc := pg_catalog.to_regprocedure('public.purge_chat_deletion_job(uuid)');
  v_def := pg_catalog.pg_get_functiondef(v_proc);
  IF pg_catalog.strpos(v_def, 'snapshot_chat_deletion_character_turn_stats') = 0
     OR NOT pg_catalog.has_function_privilege('service_role', v_proc, 'EXECUTE')
     OR pg_catalog.has_function_privilege('authenticated', v_proc, 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', v_proc, 'EXECUTE') THEN
    RAISE EXCEPTION 'purge_rpc_snapshot_or_acl_mismatch';
  END IF;

  v_proc := pg_catalog.to_regprocedure('public.get_character_turn_counts(uuid[])');
  v_def := pg_catalog.pg_get_functiondef(v_proc);
  IF pg_catalog.strpos(v_def, 'chat_deletion_character_turn_stats') = 0
     OR pg_catalog.strpos(v_def, 'g.deleted_at IS NULL') = 0
     OR pg_catalog.strpos(v_def, 'private.current_user_is_adult') = 0
     OR pg_catalog.strpos(v_def, 's.deleted_at IS NULL') = 0
     OR NOT pg_catalog.has_function_privilege('anon', v_proc, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', v_proc, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('service_role', v_proc, 'EXECUTE') THEN
    RAISE EXCEPTION 'bulk_count_rpc_missing_archive_or_existing_guards';
  END IF;

  v_proc := pg_catalog.to_regprocedure('public.get_public_character_turn_count(uuid)')::oid;
  v_def := pg_catalog.pg_get_functiondef(v_proc);
  IF pg_catalog.strpos(v_def, 'chat_deletion_character_turn_stats') = 0
     OR pg_catalog.strpos(v_def, 'g.deleted_at IS NULL') = 0
     OR pg_catalog.strpos(v_def, 'private.current_user_is_adult') = 0
     OR pg_catalog.strpos(v_def, 's.deleted_at IS NULL') = 0
     OR NOT pg_catalog.has_function_privilege('anon', v_proc, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', v_proc, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('service_role', v_proc, 'EXECUTE') THEN
    RAISE EXCEPTION 'public_count_rpc_missing_archive_or_existing_guards';
  END IF;

  RAISE NOTICE 'chat deletion cumulative turn-stat structural assertions passed';
END;
$verify$;
