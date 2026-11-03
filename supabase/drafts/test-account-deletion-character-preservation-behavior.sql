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
  v_author_session uuid := '50000000-0000-4000-8000-000000000023';
  v_author_user_message uuid := '60000000-0000-4000-8000-000000000025';
  v_author_message uuid := '60000000-0000-4000-8000-000000000023';
  v_author_turn uuid := '70000000-0000-4000-8000-000000000025';
  v_author_reservation_status text;
  v_author_group uuid := '50000000-0000-4000-8000-000000000024';
  v_author_group_turn uuid := '70000000-0000-4000-8000-000000000024';
  v_author_group_message uuid := '60000000-0000-4000-8000-000000000024';
  v_author_chat_delete_job uuid;
  v_author_storage_job uuid;
  v_author_photo uuid := 'c0000000-0000-4000-8000-000000000023';
  v_author_photo_path text := '10000000-0000-4000-8000-000000000020/50000000-0000-4000-8000-000000000023/account-delete-photo.jpg';
  v_active_author_session uuid := '50000000-0000-4000-8000-000000000026';
  v_retention_session uuid := '50000000-0000-4000-8000-000000000027';
  v_retention_job uuid;
  v_retention_claimed boolean := false;
  v_retention_purged boolean := false;
  v_active_solo_photo uuid := 'c0000000-0000-4000-8000-000000000026';
  v_active_group_photo uuid := 'c0000000-0000-4000-8000-000000000024';
  v_active_solo_path text := '10000000-0000-4000-8000-000000000020/50000000-0000-4000-8000-000000000026/account-active-solo.jpg';
  v_active_group_path text := '10000000-0000-4000-8000-000000000020/50000000-0000-4000-8000-000000000024/account-active-group.jpg';
  -- Make the independent 30-day photo retention deadline due so the test can
  -- execute the real purge RPC while the parent rows still exist.
  v_account_requested_at timestamptz := now() - interval '31 days';
  v_account_scheduled_for timestamptz := now() - interval '30 days';
  v_turn_count_before bigint;
  v_turn_count_after bigint;
  v_storage_path text := '10000000-0000-4000-8000-000000000020/20000000-0000-4000-8000-000000000020/30000000-0000-4000-8000-000000000020.jpg';
  v_due_job record;
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

  -- Account deletion cascades the author's own chat parents. Seed one solo and
  -- one group reply so the pre-cascade aggregate snapshot is behavior-tested.
  INSERT INTO public.chat_sessions (
    id, user_id, character_id, character_name, chat_mode
  ) VALUES (
    v_author_session, v_author, v_character, 'Account archived character', 'story'
  );
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_author::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_author::text, 'role', 'authenticated')::text,
    true
  );
  PERFORM public.ensure_wallet_account();
  INSERT INTO public.chat_messages (id, session_id, role, content)
  VALUES (v_author_user_message, v_author_session, 'user', 'Count this author-owned solo turn');
  SELECT r.status INTO v_author_reservation_status
  FROM public.reserve_chat_turn(
    v_author, v_author_turn, v_author_session,
    v_author_user_message, v_author_message
  ) AS r;
  IF v_author_reservation_status IS DISTINCT FROM 'reserved' THEN
    RAISE EXCEPTION 'account_deletion_solo_turn_fixture_reservation_failed';
  END IF;
  INSERT INTO public.chat_messages (id, session_id, role, content)
  VALUES (v_author_message, v_author_session, 'assistant', 'Author-owned solo reply');
  PERFORM public.settle_chat_turn(v_author, v_author_turn, v_author_message);

  -- Model a chat deletion already pending when account deletion starts.
  -- Use the real player-facing delete RPC so its snapshot + durable Storage
  -- queue are created with the production transaction and retention invariant.
  INSERT INTO public.chat_memory_photos (
    id, owner_id, chat_type, session_id, storage_path, caption
  ) VALUES (
    v_author_photo, v_author, 'single', v_author_session, v_author_photo_path,
    'pending account deletion photo'
  );
  PERFORM public.delete_chat_session_content(v_author_session);
  SELECT id INTO v_author_chat_delete_job
  FROM public.chat_deletion_jobs
  WHERE resource_type = 'single_session' AND resource_id = v_author_session
    AND owner_id = v_author;
  SELECT id INTO v_author_storage_job
  FROM public.chat_storage_deletion_jobs
  WHERE deletion_job_id = v_author_chat_delete_job
    AND bucket_id = 'personax-memory-photos'
    AND object_path = v_author_photo_path;

  IF v_author_chat_delete_job IS NULL OR v_author_storage_job IS NULL THEN
    RAISE EXCEPTION 'pending_chat_delete_rpc_must_enqueue_durable_storage_job';
  END IF;

  INSERT INTO public.chat_groups (
    id, owner_id, name, scene_mode, world_character_id
  ) VALUES (
    v_author_group, v_author, 'Author delete group', 'shared', v_character
  );
  INSERT INTO public.chat_group_members (
    id, group_id, character_id, position, character_snapshot
  ) VALUES (
    '80000000-0000-4000-8000-000000000024',
    v_author_group, v_character, 1, jsonb_build_object('name', 'Account archived character')
  );
  INSERT INTO public.chat_group_turns (
    id, group_id, user_id, request_key, request_content, status
  ) VALUES (
    v_author_group_turn, v_author_group, v_author,
    '90000000-0000-4000-8000-000000000024',
    'Author-owned group turn', 'completed'
  );
  INSERT INTO public.chat_group_messages (
    id, group_id, turn_id, sequence_no, speaker_type, character_id, content, speaker_snapshot
  ) VALUES (
    v_author_group_message, v_author_group, v_author_group_turn, 1, 'character', v_character,
    'Author-owned group reply', jsonb_build_object('name', 'Account archived character')
  );

  -- Active solo/group photos must not be queued while the account is still
  -- recoverable. They are captured only by prepare_account_deletion at day 30.
  INSERT INTO public.chat_sessions (
    id, user_id, character_id, character_name, chat_mode
  ) VALUES (
    v_active_author_session, v_author, v_character, 'Account archived character', 'story'
  );

  -- Separate pre-existing player conversation used to verify the exact 29/30-day
  -- retention boundary without altering the other pending deletion fixtures.
  INSERT INTO public.chat_sessions (
    id, user_id, character_id, character_name, chat_mode, deleted_at
  ) VALUES (
    v_retention_session, v_player, v_character, 'Retention boundary fixture',
    'story', now() - interval '29 days'
  );
  INSERT INTO public.chat_memory_photos (
    id, owner_id, chat_type, session_id, storage_path, caption
  ) VALUES (
    v_active_solo_photo, v_author, 'single', v_active_author_session,
    v_active_solo_path, 'active solo photo during account recovery'
  );
  INSERT INTO public.chat_memory_photos (
    id, owner_id, chat_type, group_id, storage_path, caption
  ) VALUES (
    v_active_group_photo, v_author, 'group', v_author_group,
    v_active_group_path, 'active group photo during account recovery'
  );

  SELECT public.get_public_character_turn_count(v_character)
  INTO v_turn_count_before;

  INSERT INTO public.account_deletion_requests (user_id, requested_at, scheduled_for)
  VALUES (v_author, v_account_requested_at, v_account_scheduled_for)
  ON CONFLICT (user_id) DO UPDATE
    SET requested_at = EXCLUDED.requested_at, scheduled_for = EXCLUDED.scheduled_for;

  -- The account worker invokes prepare through a service-role JWT without an
  -- end-user subject. This lets the internal prepare path mark the user's own
  -- chat parents deleted without impersonating a browser-authenticated update.
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', '', true);
  PERFORM pg_catalog.set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('role', 'service_role')::text,
    true
  );

  SELECT p.batch_id, p.batch_status INTO v_batch, v_status
  FROM public.prepare_account_deletion(v_author) AS p;

  IF v_batch IS NULL OR v_status IS DISTINCT FROM 'deleting' THEN
    RAISE EXCEPTION 'account_deletion_prepare_did_not_reach_deleting_state';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.chat_deletion_jobs
    WHERE resource_type = 'single_session'
      AND resource_id = v_active_author_session
      AND owner_id = v_author
      AND deleted_at = v_account_requested_at
      AND purge_after = v_account_requested_at + interval '30 days'
      AND purge_after = deleted_at + interval '30 days'
      AND status = 'queued'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_deletion_jobs
    WHERE resource_type = 'group'
      AND resource_id = v_author_group
      AND owner_id = v_author
      AND deleted_at = v_account_requested_at
      AND purge_after = v_account_requested_at + interval '30 days'
      AND purge_after = deleted_at + interval '30 days'
      AND status = 'queued'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_sessions
    WHERE id = v_active_author_session
      AND user_id = v_author
      AND deleted_at = v_account_requested_at
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_groups
    WHERE id = v_author_group
      AND owner_id = v_author
      AND deleted_at = v_account_requested_at
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_storage_deletion_jobs
    WHERE bucket_id = 'personax-memory-photos'
      AND object_path = v_active_solo_path
      AND owner_id = v_author
      AND resource_type = 'single_session'
      AND resource_id = v_active_author_session
      AND status = 'queued'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_storage_deletion_jobs
    WHERE bucket_id = 'personax-memory-photos'
      AND object_path = v_active_group_path
      AND owner_id = v_author
      AND resource_type = 'group'
      AND resource_id = v_author_group
      AND status = 'queued'
  ) THEN
    RAISE EXCEPTION 'account_deletion_must_queue_active_solo_and_group_photos_for_30_day_recovery_window';
  END IF;

  -- Exercise the real day-30 purge while the Auth cascade has not yet removed
  -- the parents. The account-photo helper must have marked each parent with
  -- exactly the queue's deleted_at timestamp, or purge_chat_deletion_job()
  -- would fail its parent/job consistency check and retry forever.
  FOR v_due_job IN
    SELECT claimed.job_id
    FROM public.claim_chat_deletion_jobs(10) AS claimed
    WHERE claimed.resource_id IN (v_active_author_session, v_author_group)
  LOOP
    PERFORM public.purge_chat_deletion_job(v_due_job.job_id);
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM public.chat_deletion_jobs
    WHERE resource_id IN (v_active_author_session, v_author_group)
      AND status IS DISTINCT FROM 'completed'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_sessions
    WHERE id = v_active_author_session
      AND deleted_at = v_account_requested_at
      AND session_data = '{}'::jsonb
      AND character_snapshot = '{}'::jsonb
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_groups
    WHERE id = v_author_group
      AND deleted_at = v_account_requested_at
      AND name = '已刪除對話'
  ) THEN
    RAISE EXCEPTION 'account_photo_parent_must_be_purgeable_before_auth_cascade';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.chat_deletion_character_turn_stats
    WHERE resource_type = 'single_session'
      AND resource_id = v_author_session
      AND character_id = v_character
      AND turn_count = 1
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_deletion_character_turn_stats
    WHERE resource_type = 'group'
      AND resource_id = v_author_group
      AND character_id = v_character
      AND turn_count = 1
  ) THEN
    RAISE EXCEPTION 'account_deletion_must_snapshot_solo_and_group_character_turn_counts';
  END IF;

  SELECT public.get_public_character_turn_count(v_character)
  INTO v_turn_count_after;
  IF v_turn_count_after IS DISTINCT FROM v_turn_count_before THEN
    RAISE EXCEPTION 'account_deletion_must_preserve_public_character_cumulative_turn_count';
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

  -- Existing pending deletion jobs are independent of Auth ownership. The
  -- photo metadata cascades with its chat session, but the durable Storage job
  -- must remain available to the chat purge worker.
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_deletion_jobs
    WHERE id = v_author_chat_delete_job AND status = 'queued'
      AND purge_after = deleted_at + interval '30 days'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_storage_deletion_jobs
    WHERE id = v_author_storage_job
      AND deletion_job_id = v_author_chat_delete_job
      AND bucket_id = 'personax-memory-photos'
      AND object_path = v_author_photo_path
      AND status = 'queued'
  ) OR EXISTS (
    SELECT 1 FROM public.chat_memory_photos WHERE id = v_author_photo
  ) OR EXISTS (
    SELECT 1 FROM public.chat_memory_photos
    WHERE id IN (v_active_solo_photo, v_active_group_photo)
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_deletion_jobs
    WHERE resource_id = v_active_author_session
      AND resource_type = 'single_session'
      AND owner_id = v_author
      AND purge_after = v_account_requested_at + interval '30 days'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_deletion_jobs
    WHERE resource_id = v_author_group
      AND resource_type = 'group'
      AND owner_id = v_author
      AND purge_after = v_account_requested_at + interval '30 days'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_storage_deletion_jobs
    WHERE object_path = v_active_solo_path
      AND status = 'queued'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_storage_deletion_jobs
    WHERE object_path = v_active_group_path
      AND status = 'queued'
  ) THEN
    RAISE EXCEPTION 'account_auth_cascade_must_preserve_pending_and_account_photo_storage_jobs';
  END IF;


  -- Explicit 29/30-day boundary regression: a job at day 29 must not be claimed;
  -- moving the same exact job to day 30 must make it claimable and purgeable.
  INSERT INTO public.chat_deletion_jobs (
    resource_type, resource_id, owner_id, deleted_at, purge_after
  ) VALUES (
    'single_session', v_retention_session, v_player,
    now() - interval '29 days', now() + interval '1 day'
  ) RETURNING id INTO v_retention_job;

  PERFORM pg_catalog.set_config('request.jwt.claim.sub', '', true);
  PERFORM pg_catalog.set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object('role', 'service_role')::text,
    true
  );

  SELECT EXISTS (
    SELECT 1
    FROM public.claim_chat_deletion_jobs(50) AS claimed
    WHERE claimed.job_id = v_retention_job
  ) INTO v_retention_claimed;
  IF v_retention_claimed
     OR NOT EXISTS (
       SELECT 1 FROM public.chat_deletion_jobs
       WHERE id = v_retention_job AND status = 'queued'
         AND purge_after > clock_timestamp()
     ) THEN
    RAISE EXCEPTION 'chat_retention_day_29_must_not_be_claimed';
  END IF;

  UPDATE public.chat_sessions
  SET deleted_at = now() - interval '30 days'
  WHERE id = v_retention_session AND user_id = v_player;
  UPDATE public.chat_deletion_jobs
  SET deleted_at = now() - interval '30 days',
      purge_after = (now() - interval '30 days') + interval '30 days'
  WHERE id = v_retention_job;

  SELECT EXISTS (
    SELECT 1
    FROM public.claim_chat_deletion_jobs(50) AS claimed
    WHERE claimed.job_id = v_retention_job
  ) INTO v_retention_claimed;
  IF NOT v_retention_claimed THEN
    RAISE EXCEPTION 'chat_retention_day_30_must_be_claimed';
  END IF;

  SELECT public.purge_chat_deletion_job(v_retention_job)
  INTO v_retention_purged;
  IF v_retention_purged IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'chat_retention_day_30_purge_rpc_returned_false';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_deletion_jobs
    WHERE id = v_retention_job AND status = 'completed'
  ) THEN
    RAISE EXCEPTION 'chat_retention_day_30_job_not_completed';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.character_asset_cleanup_jobs
    WHERE character_id = v_character
  ) THEN
    RAISE EXCEPTION 'account_deletion_must_not_queue_retained_character_assets';
  END IF;

  -- Once Auth FK cascades remove the author's own active chat parents, their
  -- saved aggregates become authoritative. The public count must still equal
  -- the pre-deletion value (and must not have double-counted them pre-cascade).
  SELECT public.get_public_character_turn_count(v_character)
  INTO v_turn_count_after;
  IF v_turn_count_after IS DISTINCT FROM v_turn_count_before THEN
    RAISE EXCEPTION 'account_auth_cascade_must_activate_snapshots_without_changing_character_turn_count';
  END IF;

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
