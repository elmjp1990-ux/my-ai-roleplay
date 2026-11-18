BEGIN;

DO $suggestion_edit_contract$
DECLARE
  v_single text;
  v_group text;
  v_single_acl text;
  v_group_acl text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.update_chat_message_suggested_replies(uuid,jsonb)'::regprocedure
  ) INTO v_single;
  SELECT pg_catalog.pg_get_functiondef(
    'public.update_chat_group_turn_suggested_replies(uuid,jsonb)'::regprocedure
  ) INTO v_group;

  IF position('suggestion_message_not_latest' IN v_single) = 0
     OR position('suggestion_message_not_found_or_not_owned' IN v_single) = 0
     OR position('account_deletion_pending' IN v_single) = 0
     OR position('suggested_replies = p_suggested_replies' IN v_single) = 0 THEN
    RAISE EXCEPTION 'single_suggestion_edit_owner_or_latest_guard_missing';
  END IF;
  IF position('suggestion_turn_not_latest' IN v_group) = 0
     OR position('suggestion_turn_not_found_or_not_owned' IN v_group) = 0
     OR position('account_deletion_pending' IN v_group) = 0
     OR position('suggested_replies = p_suggested_replies' IN v_group) = 0 THEN
    RAISE EXCEPTION 'group_suggestion_edit_owner_or_latest_guard_missing';
  END IF;

  SELECT pg_catalog.pg_get_function_result(p.oid)
  INTO v_single_acl
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.update_chat_message_suggested_replies(uuid,jsonb)'::regprocedure;
  SELECT pg_catalog.pg_get_function_result(p.oid)
  INTO v_group_acl
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.update_chat_group_turn_suggested_replies(uuid,jsonb)'::regprocedure;
  IF v_single_acl <> 'jsonb' OR v_group_acl <> 'jsonb' THEN
    RAISE EXCEPTION 'suggestion_edit_rpc_return_shape_invalid';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.update_chat_message_suggested_replies(uuid,jsonb)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.update_chat_message_suggested_replies(uuid,jsonb)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.update_chat_group_turn_suggested_replies(uuid,jsonb)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.update_chat_group_turn_suggested_replies(uuid,jsonb)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'suggestion_edit_rpc_grants_invalid';
  END IF;
END;
$suggestion_edit_contract$;

ROLLBACK;
