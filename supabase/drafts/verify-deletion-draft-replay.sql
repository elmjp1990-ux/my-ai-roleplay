DO $$
BEGIN
  IF to_regclass('public.chat_deletion_character_history') IS NULL THEN RAISE EXCEPTION 'missing chat deletion character history'; END IF;
  IF to_regclass('public.chat_deletion_character_turn_stats') IS NULL THEN RAISE EXCEPTION 'missing chat deletion turn stats'; END IF;
  IF to_regclass('public.character_asset_cleanup_jobs') IS NULL THEN RAISE EXCEPTION 'missing character asset cleanup queue'; END IF;
  IF to_regclass('private.character_private_draft_origins') IS NULL THEN RAISE EXCEPTION 'missing private draft origin marker table'; END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='private.character_private_draft_origins'::regclass) THEN RAISE EXCEPTION 'private draft origin table must enable RLS'; END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.character_asset_cleanup_jobs'::regclass) THEN RAISE EXCEPTION 'asset cleanup queue must enable RLS'; END IF;
  IF NOT has_function_privilege('authenticated','public.soft_delete_character(uuid)','EXECUTE') THEN RAISE EXCEPTION 'authenticated must retain soft_delete_character RPC'; END IF;
  IF has_function_privilege('anon','public.soft_delete_character(uuid)','EXECUTE') THEN RAISE EXCEPTION 'anon must not execute soft_delete_character'; END IF;
  IF NOT has_function_privilege('service_role','public.claim_character_asset_cleanup_jobs(integer)','EXECUTE') THEN RAISE EXCEPTION 'service_role must execute cleanup claim RPC'; END IF;
  IF has_function_privilege('authenticated','public.claim_character_asset_cleanup_jobs(integer)','EXECUTE') THEN RAISE EXCEPTION 'authenticated must not execute cleanup claim RPC'; END IF;
  IF NOT has_function_privilege('authenticated','public.delete_chat_session_content(uuid)','EXECUTE')
     OR has_function_privilege('anon','public.delete_chat_session_content(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'single_chat_delete_rpc_acl_mismatch';
  END IF;
  IF NOT has_function_privilege('authenticated','public.delete_chat_group_with_related_data(uuid)','EXECUTE')
     OR has_function_privilege('anon','public.delete_chat_group_with_related_data(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'group_chat_delete_rpc_acl_mismatch';
  END IF;
  IF NOT has_function_privilege('service_role','public.purge_chat_deletion_job(uuid)','EXECUTE')
     OR has_function_privilege('authenticated','public.purge_chat_deletion_job(uuid)','EXECUTE')
     OR has_function_privilege('anon','public.purge_chat_deletion_job(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'chat_purge_rpc_must_be_service_only';
  END IF;
  IF NOT has_function_privilege('service_role','public.finish_character_asset_cleanup_job(uuid,text,text)','EXECUTE')
     OR has_function_privilege('authenticated','public.finish_character_asset_cleanup_job(uuid,text,text)','EXECUTE')
     OR has_function_privilege('anon','public.finish_character_asset_cleanup_job(uuid,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'asset_cleanup_finalize_rpc_must_be_service_only';
  END IF;
  IF has_table_privilege('anon','private.character_private_draft_origins','SELECT') THEN RAISE EXCEPTION 'anon must not read private draft origin markers'; END IF;
  IF has_table_privilege('authenticated','private.character_private_draft_origins','SELECT') THEN RAISE EXCEPTION 'authenticated must not read private draft origin markers'; END IF;
  IF has_table_privilege('service_role','private.character_private_draft_origins','SELECT') THEN RAISE EXCEPTION 'service_role must not directly read private draft origin markers'; END IF;
  IF has_table_privilege('authenticated','public.character_asset_cleanup_jobs','SELECT') THEN RAISE EXCEPTION 'authenticated must not directly read asset cleanup queue'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='record_character_private_draft_origin' AND tgrelid='public.characters'::regclass AND NOT tgisinternal) THEN RAISE EXCEPTION 'missing AFTER INSERT draft origin trigger'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='preserve_character_first_publication_timestamp' AND tgrelid='public.characters'::regclass AND NOT tgisinternal) THEN RAISE EXCEPTION 'missing publication immutability trigger'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='prevent_reuse_queued_character_avatar_video' AND tgrelid='public.characters'::regclass AND NOT tgisinternal) THEN RAISE EXCEPTION 'missing avatar path reuse guard'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='prevent_reuse_queued_character_illustration' AND tgrelid='public.character_illustrations'::regclass AND NOT tgisinternal) THEN RAISE EXCEPTION 'missing illustration path reuse guard'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='prevent_character_story_delete_with_conversations' AND tgrelid='public.character_stories'::regclass AND NOT tgisinternal) THEN RAISE EXCEPTION 'missing legacy story history guard'; END IF;
  IF EXISTS (SELECT 1 FROM public.character_asset_cleanup_jobs) THEN RAISE EXCEPTION 'cleanup queue must remain empty during schema replay'; END IF;
  IF EXISTS (SELECT 1 FROM private.character_private_draft_origins) THEN RAISE EXCEPTION 'draft origin marker table must remain empty during schema replay'; END IF;
END;
$$;
