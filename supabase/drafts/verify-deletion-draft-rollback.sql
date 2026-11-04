DO $$
BEGIN
  IF to_regclass('public.chat_deletion_character_history') IS NOT NULL THEN RAISE EXCEPTION 'chat deletion draft table leaked after rollback'; END IF;
  IF to_regclass('public.chat_deletion_character_turn_stats') IS NOT NULL THEN RAISE EXCEPTION 'chat deletion stats table leaked after rollback'; END IF;
  IF to_regclass('public.character_asset_cleanup_jobs') IS NOT NULL THEN RAISE EXCEPTION 'asset cleanup queue leaked after rollback'; END IF;
  IF to_regclass('private.character_private_draft_origins') IS NOT NULL THEN RAISE EXCEPTION 'private draft origin table leaked after rollback'; END IF;
  IF EXISTS (SELECT 1 FROM auth.users WHERE id='10000000-0000-4000-8000-000000000001') THEN RAISE EXCEPTION 'synthetic auth user leaked after rollback'; END IF;
  IF EXISTS (SELECT 1 FROM public.profiles WHERE id='10000000-0000-4000-8000-000000000001') THEN RAISE EXCEPTION 'synthetic profile leaked after rollback'; END IF;
  IF EXISTS (SELECT 1 FROM public.characters WHERE id::text LIKE '20000000-0000-4000-8000-00000000000%') THEN RAISE EXCEPTION 'synthetic character leaked after rollback'; END IF;
END;
$$;
