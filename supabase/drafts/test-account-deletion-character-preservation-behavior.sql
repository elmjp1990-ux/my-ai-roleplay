-- DRAFT ONLY — disposable PostgreSQL behavior test, executed inside replay transaction.
-- The account author is distinct from the player who owns the existing chats.
DO $$
DECLARE
  v_author uuid := '10000000-0000-4000-8000-000000000020';
  v_player uuid := '10000000-0000-4000-8000-000000000001';
  v_character uuid := '20000000-0000-4000-8000-000000000020';
  v_session uuid := '50000000-0000-4000-8000-000000000020';
  v_group uuid := '50000000-0000-4000-8000-000000000021';
  v_group_turn uuid := '70000000-0000-4000-8000-000000000020';
  v_group_message uuid := '60000000-0000-4000-8000-000000000020';
  v_illustration uuid := '30000000-0000-4000-8000-000000000020';
  v_schedule uuid := '40000000-0000-4000-8000-000000000020';
  v_batch uuid;
  v_status text;
  v_new_session uuid := '50000000-0000-4000-8000-000000000022';
  v_new_session_rejected boolean := false;
  v_storage_path text := '10000000-0000-4000-8000-000000000020/20000000-0000-4000-8000-000000000020/30000000-0000-4000-8000-000000000020.jpg';
BEGIN
  INSERT INTO auth.users (id) VALUES (v_author) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.profiles (id, handle, nickname)
  VALUES (v_author, 'pr200-author-archive', 'Archived Creator')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.characters (
    id, author_id, name, visibility, review_status, rights_confirmed,
    avatar_video_path
  ) VALUES (
    v_character, v_author, 'Account archived character', 'public', 'approved',
    true,
    '10000000-0000-4000-8000-000000000020/20000000-0000-4000-8000-000000000020/clip.mp4'
  );

  INSERT INTO public.character_private_info (character_id, author_id, private_info)
  VALUES (v_character, v_author, 'private author setting survives account archival');
  INSERT INTO public.character_schedule_descriptions (character_id, author_id, description)
  VALUES (v_character, v_author, 'Weekly schedule survives account archival');
  INSERT INTO public.character_schedules (
    id, character_id, weekday, day_type, start_time, end_time, location_key, activity
  ) VALUES (
    v_schedule, v_character, 1, 'any', '09:00', '10:00', 'cafe', 'Works at the cafe'
  );
  INSERT INTO public.character_illustrations (
    id, character_id, author_id, storage_path, asset_type, sort_order
  ) VALUES (
    v_illustration, v_character, v_author, v_storage_path, 'primary', 0
  );

  -- Existing chats belong to another player, not the author being deleted.
  INSERT INTO public.chat_sessions (
    id, user_id, character_id, character_name, chat_mode, character_snapshot
  ) VALUES (
    v_session, v_player, v_character, 'Account archived character', 'story',
    jsonb_build_object('name', 'Account archived character')
  );

  INSERT INTO public.chat_groups (
    id, owner_id, name, scene_mode, world_character_id
  ) VALUES (
    v_group, v_player, 'PR200 account archive', 'shared', v_character
  );
  INSERT INTO public.chat_group_members (
    id, group_id, character_id, position, character_snapshot
  ) VALUES (
    '80000000-0000-4000-8000-000000000020',
    v_group, v_character, 1, jsonb_build_object('name', 'Account archived character')
  );
  INSERT INTO public.chat_group_turns (
    id, group_id, user_id, request_key, request_content, status
  ) VALUES (
    v_group_turn, v_group, v_player,
    '90000000-0000-4000-8000-000000000020',
    'Existing player group turn', 'completed'
  );
  INSERT INTO public.chat_group_messages (
    id, group_id, turn_id, sequence_no, speaker_type, character_id, content, speaker_snapshot
  ) VALUES (
    v_group_message, v_group, v_group_turn, 1, 'character', v_character,
    'Existing character reply', jsonb_build_object('name', 'Account archived character')
  );

  INSERT INTO public.account_deletion_requests (user_id, requested_at, scheduled_for)
  VALUES (v_author, now() - interval '1 hour', now() - interval '1 minute')
  ON CONFLICT (user_id) DO UPDATE
    SET requested_at = EXCLUDED.requested_at, scheduled_for = EXCLUDED.scheduled_for;

  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_author::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claim.role', 'service_role', true);
  -- Supabase auth.jwt() reads the complete claims JSON, not the legacy
  -- request.jwt.claim.role setting used by auth.role().
  PERFORM pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_author::text, 'role', 'service_role')::text,
    true
  );

  SELECT p.batch_id, p.batch_status INTO v_batch, v_status
  FROM public.prepare_account_deletion(v_author) AS p;

  IF v_batch IS NULL OR v_status IS DISTINCT FROM 'deleting' THEN
    RAISE EXCEPTION 'account_deletion_prepare_did_not_reach_deleting_state';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.characters
    WHERE id = v_character
      AND author_id IS NULL
      AND account_archived_at IS NOT NULL
      AND deleted_at IS NULL
      AND visibility = 'public'
      AND review_status = 'approved'
      AND creator_display_name = 'Archived Creator'
      AND avatar_video_path LIKE '%/clip.mp4'
  ) THEN
    RAISE EXCEPTION 'account_deletion_must_preserve_character_and_original_public_state';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.character_private_info
    WHERE character_id = v_character AND author_id IS NULL
      AND private_info = 'private author setting survives account archival'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.character_schedule_descriptions
    WHERE character_id = v_character AND author_id IS NULL
      AND description = 'Weekly schedule survives account archival'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.character_schedules
    WHERE id = v_schedule AND character_id = v_character
  ) OR NOT EXISTS (
    SELECT 1 FROM public.character_illustrations
    WHERE id = v_illustration AND character_id = v_character
      AND author_id IS NULL AND storage_path = v_storage_path
  ) THEN
    RAISE EXCEPTION 'account_deletion_must_preserve_character_children_and_media';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.chat_sessions
    WHERE id = v_session AND user_id = v_player
      AND deleted_at IS NULL AND character_id = v_character
      AND character_snapshot->>'characterStatus' = 'offline'
      AND character_snapshot->>'creatorDisplayName' = 'Archived Creator'
      AND character_snapshot->>'creatorProfileAvailable' = 'false'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_groups
    WHERE id = v_group AND owner_id = v_player
      AND deleted_at IS NULL AND world_character_id = v_character
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_group_members
    WHERE group_id = v_group AND character_id = v_character
      AND character_snapshot->>'characterStatus' = 'offline'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_group_messages
    WHERE id = v_group_message AND group_id = v_group
      AND character_id = v_character
      AND speaker_snapshot->>'creatorDisplayName' = 'Archived Creator'
  ) THEN
    RAISE EXCEPTION 'account_deletion_must_preserve_other_players_existing_chats';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.account_deletion_archive_batches
    WHERE id = v_batch AND status = 'deleting'
  ) THEN
    RAISE EXCEPTION 'account_deletion_batch_state_mismatch';
  END IF;

  -- Existing player can still access the archived character through the old
  -- session, but cannot create a new session for the account-archived work.
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_player::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_player::text, 'role', 'authenticated')::text,
    true
  );
  IF public.character_can_start_chat(v_character) IS DISTINCT FROM false
     OR public.can_open_encounter_session(v_character) IS DISTINCT FROM false
     OR private.user_has_existing_character_session(v_character) IS DISTINCT FROM true
     OR private.can_read_character_asset('character-illustrations', v_storage_path) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'archived_character_must_block_new_entry_but_preserve_existing_player_access';
  END IF;

  BEGIN
    INSERT INTO public.chat_sessions (
      id, user_id, character_id, character_name, chat_mode
    ) VALUES (
      v_new_session, v_player, v_character, 'Account archived character', 'story'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_new_session_rejected := true;
  END;
  IF NOT v_new_session_rejected OR EXISTS (
    SELECT 1 FROM public.chat_sessions WHERE id = v_new_session
  ) THEN
    RAISE EXCEPTION 'account_archived_character_new_session_must_be_rejected';
  END IF;

  -- Simulate Auth Admin deletion while the old JWT is still present. The stale
  -- author token must no longer read retained media; the unrelated player token
  -- must continue to read the same existing session and media.
  DELETE FROM auth.users WHERE id = v_author;
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_author::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_author::text, 'role', 'authenticated')::text, true);
  IF public.account_is_active() IS DISTINCT FROM false
     OR private.user_has_existing_character_session(v_character) IS DISTINCT FROM false
     OR private.can_read_character_asset('character-illustrations', v_storage_path) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'deleted_auth_user_stale_jwt_must_lose_retained_character_access';
  END IF;

  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_player::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_player::text, 'role', 'authenticated')::text, true);
  IF public.account_is_active() IS DISTINCT FROM true
     OR private.user_has_existing_character_session(v_character) IS DISTINCT FROM true
     OR private.can_read_character_asset('character-illustrations', v_storage_path) IS DISTINCT FROM true
     OR NOT EXISTS (
       SELECT 1 FROM public.chat_sessions
       WHERE id = v_session AND deleted_at IS NULL AND character_id = v_character
     ) THEN
    RAISE EXCEPTION 'other_player_existing_chat_and_media_access_must_survive_author_auth_deletion';
  END IF;
END;
$$;
