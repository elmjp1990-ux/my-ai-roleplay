DO $$
DECLARE
  v_user uuid := '10000000-0000-4000-8000-000000000001';
  v_legacy_private uuid := '20000000-0000-4000-8000-000000000001';
  v_legacy_public uuid := '20000000-0000-4000-8000-000000000002';
  v_legacy_former_public uuid := '20000000-0000-4000-8000-000000000003';
  v_new_draft uuid := '20000000-0000-4000-8000-000000000004';
  v_chat_draft uuid := '20000000-0000-4000-8000-000000000005';
  v_story_draft uuid := '20000000-0000-4000-8000-000000000006';
  v_asset_draft uuid := '20000000-0000-4000-8000-000000000007';
  v_group_draft uuid := '20000000-0000-4000-8000-000000000008';
  v_group_other_draft uuid := '20000000-0000-4000-8000-000000000009';
  v_encounter_draft uuid := '20000000-0000-4000-8000-000000000010';
  v_encounter_state uuid := '80000000-0000-4000-8000-000000000001';
  v_encounter_diary uuid := '80000000-0000-4000-8000-000000000002';
  v_encounter_session uuid := '50000000-0000-4000-8000-000000000003';
  v_encounter_user_message uuid := '60000000-0000-4000-8000-000000000004';
  v_encounter_assistant_message uuid := '60000000-0000-4000-8000-000000000005';
  v_encounter_turn uuid := '70000000-0000-4000-8000-000000000004';
  v_encounter_turn_status text;
  v_encounter_evidence jsonb;
  v_chat_session uuid := '50000000-0000-4000-8000-000000000002';
  v_chat_user_message uuid := '60000000-0000-4000-8000-000000000002';
  v_chat_assistant_message uuid := '60000000-0000-4000-8000-000000000003';
  v_chat_turn uuid := '70000000-0000-4000-8000-000000000002';
  v_group_continue_turn uuid;
  v_group_deleted_character_turn uuid;
  v_chat_turn_status text;
  v_group uuid := '50000000-0000-4000-8000-000000000001';
  v_group_turn uuid := '60000000-0000-4000-8000-000000000001';
  v_asset_file uuid := '30000000-0000-4000-8000-000000000001';
  v_story uuid := '40000000-0000-4000-8000-000000000001';
  v_deleted_at timestamptz;
  v_group_deleted_at timestamptz;
  v_first_published_at timestamptz;
  v_avatar_path text;
  v_illustration_path text;
BEGIN
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);

  -- Upserting a pre-existing legacy private draft must not manufacture an origin marker.
  INSERT INTO public.characters (id, author_id, name, visibility, review_status)
  VALUES (v_legacy_private, v_user, 'Legacy private draft upsert', 'private', 'draft')
  ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;
  IF EXISTS (SELECT 1 FROM private.character_private_draft_origins WHERE character_id = v_legacy_private) THEN
    RAISE EXCEPTION 'legacy_upsert_must_not_create_private_draft_origin';
  END IF;

  -- A legacy private draft with no origin proof is archived, never hard-deleted.
  v_deleted_at := public.soft_delete_character(v_legacy_private);
  IF NOT EXISTS (SELECT 1 FROM public.characters WHERE id = v_legacy_private AND deleted_at = v_deleted_at AND visibility = 'private' AND review_status = 'draft') THEN
    RAISE EXCEPTION 'legacy_private_draft_must_soft_delete';
  END IF;
  BEGIN
    UPDATE public.characters SET first_published_at = pg_catalog.statement_timestamp() WHERE id = v_legacy_private;
    RAISE EXCEPTION 'expected_server_managed_publication_marker_rejection';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- A public legacy row is backfilled at rollout; changing it to private cannot erase publication history.
  SELECT first_published_at INTO v_first_published_at FROM public.characters WHERE id = v_legacy_public;
  IF v_first_published_at IS NULL THEN RAISE EXCEPTION 'legacy_public_row_was_not_backfilled'; END IF;
  UPDATE public.characters SET visibility = 'private', review_status = 'draft' WHERE id = v_legacy_public;
  BEGIN
    UPDATE public.characters SET first_published_at = NULL WHERE id = v_legacy_public;
    RAISE EXCEPTION 'expected_immutable_first_publication_rejection';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  v_deleted_at := public.soft_delete_character(v_legacy_public);
  IF NOT EXISTS (SELECT 1 FROM public.characters WHERE id = v_legacy_public AND deleted_at = v_deleted_at AND first_published_at IS NOT NULL) THEN
    RAISE EXCEPTION 'legacy_published_character_must_soft_delete';
  END IF;

  -- A formerly-public row already private before rollout has no trustworthy origin marker.
  IF EXISTS (SELECT 1 FROM private.character_private_draft_origins WHERE character_id = v_legacy_former_public) THEN
    RAISE EXCEPTION 'legacy_former_public_row_must_not_receive_origin_marker';
  END IF;
  v_deleted_at := public.soft_delete_character(v_legacy_former_public);
  IF NOT EXISTS (SELECT 1 FROM public.characters WHERE id = v_legacy_former_public AND deleted_at = v_deleted_at) THEN
    RAISE EXCEPTION 'legacy_former_public_character_must_soft_delete';
  END IF;

  -- A genuine new private draft receives a marker and can be hard-deleted only when unused.
  INSERT INTO public.characters (id, author_id, name, visibility, review_status)
  VALUES (v_new_draft, v_user, 'New private draft', 'private', 'draft');
  IF NOT EXISTS (SELECT 1 FROM private.character_private_draft_origins WHERE character_id = v_new_draft) THEN
    RAISE EXCEPTION 'new_private_draft_origin_marker_missing';
  END IF;
  v_deleted_at := public.soft_delete_character(v_new_draft);
  IF EXISTS (SELECT 1 FROM public.characters WHERE id = v_new_draft) THEN
    RAISE EXCEPTION 'unused_new_private_draft_should_hard_delete';
  END IF;
  IF EXISTS (SELECT 1 FROM private.character_private_draft_origins WHERE character_id = v_new_draft) THEN
    RAISE EXCEPTION 'origin_marker_should_cascade_after_hard_delete';
  END IF;

  -- A new private draft with a single-chat session is preserved and the transcript link remains intact.
  INSERT INTO public.characters (id, author_id, name, visibility, review_status)
  VALUES (v_chat_draft, v_user, 'Private draft with chat history', 'private', 'draft');
  INSERT INTO public.chat_sessions (id, user_id, character_id, character_name, chat_mode)
  VALUES (v_chat_session, v_user, v_chat_draft, 'Private draft with chat history', 'story');
  v_deleted_at := public.soft_delete_character(v_chat_draft);
  IF NOT EXISTS (SELECT 1 FROM public.characters WHERE id = v_chat_draft AND deleted_at = v_deleted_at) THEN
    RAISE EXCEPTION 'character_with_chat_history_must_soft_delete';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chat_sessions WHERE id = v_chat_session AND deleted_at IS NULL AND character_snapshot ? 'deletedAt') THEN
    RAISE EXCEPTION 'existing_chat_session_snapshot_not_preserved';
  END IF;
  IF public.character_can_start_chat(v_chat_draft) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'archived_character_must_not_start_a_new_chat';
  END IF;

  -- Existing single-chat sessions remain writable after character archive:
  -- reserve a normal paid turn, then persist its assistant reply through the
  -- same trigger-guarded writer path used by the chat-turn Edge Function.
  PERFORM public.ensure_wallet_account();
  INSERT INTO public.chat_messages (id, session_id, role, content)
  VALUES (v_chat_user_message, v_chat_session, 'user', 'I am continuing our old conversation');
  SELECT r.status INTO v_chat_turn_status
  FROM public.reserve_chat_turn(
    v_user, v_chat_turn, v_chat_session, v_chat_user_message, v_chat_assistant_message
  ) AS r;
  IF v_chat_turn_status IS DISTINCT FROM 'reserved' THEN
    RAISE EXCEPTION 'existing_single_chat_turn_reservation_failed_after_character_delete';
  END IF;
  INSERT INTO public.chat_messages (id, session_id, role, content)
  VALUES (v_chat_assistant_message, v_chat_session, 'assistant', 'I am still here; let us continue.');
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_messages
    WHERE id = v_chat_assistant_message
      AND session_id = v_chat_session
      AND role = 'assistant'
      AND content = 'I am still here; let us continue.'
      AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'existing_single_chat_assistant_reply_rejected_after_character_delete';
  END IF;

  -- A legacy conversation referencing a story template is player history, even if the draft was never public.
  INSERT INTO public.characters (id, author_id, name, visibility, review_status)
  VALUES (v_story_draft, v_user, 'Private draft with story history', 'private', 'draft');
  INSERT INTO public.character_stories (id, character_id, story_name)
  VALUES (v_story, v_story_draft, 'Legacy story template');
  INSERT INTO public.conversations (user_id, story_id, title)
  VALUES (v_user, v_story, 'Legacy conversation');
  v_deleted_at := public.soft_delete_character(v_story_draft);
  IF NOT EXISTS (SELECT 1 FROM public.characters WHERE id = v_story_draft AND deleted_at = v_deleted_at) THEN
    RAISE EXCEPTION 'character_with_legacy_conversation_must_soft_delete';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.character_stories WHERE id = v_story AND visibility = 'private') THEN
    RAISE EXCEPTION 'story_template_should_be_archived_not_deleted';
  END IF;
  BEGIN
    DELETE FROM public.character_stories WHERE id = v_story;
    RAISE EXCEPTION 'expected_story_history_delete_rejection';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- A group is one player with multiple AI characters. Deleting one character
  -- must preserve the group, its transcript, its speaker snapshot, and other members.
  INSERT INTO public.characters (id, author_id, name, visibility, review_status)
  VALUES
    (v_group_draft, v_user, 'Private draft in existing group', 'private', 'draft'),
    (v_group_other_draft, v_user, 'Other AI in same group', 'private', 'draft');
  INSERT INTO public.chat_groups (id, owner_id, name, scene_mode, world_character_id, player_name)
  VALUES (v_group, v_user, 'PR200 group test', 'shared', v_group_draft, 'Test player');
  INSERT INTO public.chat_group_members (group_id, character_id, position, character_snapshot)
  VALUES
    (v_group, v_group_draft, 1, jsonb_build_object('id', v_group_draft, 'name', 'Private draft in existing group')),
    (v_group, v_group_other_draft, 2, jsonb_build_object('id', v_group_other_draft, 'name', 'Other AI in same group'));
  INSERT INTO public.chat_group_turns (id, group_id, user_id, request_key, request_content)
  VALUES (v_group_turn, v_group, v_user, '70000000-0000-4000-8000-000000000001', 'Hello group');
  INSERT INTO public.chat_group_messages (group_id, turn_id, sequence_no, speaker_type, character_id, content, speaker_snapshot)
  VALUES (v_group, v_group_turn, 1, 'character', v_group_draft, 'Existing group reply', jsonb_build_object('id', v_group_draft, 'name', 'Private draft in existing group'));

  v_deleted_at := public.soft_delete_character(v_group_draft);
  v_group_deleted_at := v_deleted_at;
  IF NOT EXISTS (
    SELECT 1 FROM public.characters
    WHERE id = v_group_draft AND deleted_at = v_deleted_at AND visibility = 'private'
  ) THEN
    RAISE EXCEPTION 'character_with_group_history_must_soft_delete';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_groups
    WHERE id = v_group AND deleted_at IS NULL AND world_character_id = v_group_draft
  ) THEN
    RAISE EXCEPTION 'existing_group_or_world_character_reference_was_lost';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_group_members
    WHERE group_id = v_group AND character_id = v_group_draft
      AND character_snapshot ? 'deletedAt'
  ) THEN
    RAISE EXCEPTION 'existing_group_member_snapshot_not_preserved';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_group_messages
    WHERE group_id = v_group AND character_id = v_group_draft
      AND speaker_snapshot ? 'deletedAt'
      AND content = 'Existing group reply'
  ) THEN
    RAISE EXCEPTION 'existing_group_message_or_speaker_snapshot_not_preserved';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_group_members
    WHERE group_id = v_group AND character_id = v_group_other_draft
      AND character_snapshot->>'name' = 'Other AI in same group'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.characters
    WHERE id = v_group_other_draft AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'other_group_character_was_affected_by_single_character_delete';
  END IF;

  -- Existing group membership remains durable after character deletion.
  -- Both characters continue taking turns and both remain billable (3 silver each).
  v_group_continue_turn := public.append_chat_group_mock_turn(
    v_group,
    '70000000-0000-4000-8000-000000000003',
    'Continue the existing group after one character was deleted'
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_group_messages
    WHERE group_id = v_group
      AND turn_id = v_group_continue_turn
      AND speaker_type = 'character'
      AND character_id = v_group_other_draft
  ) THEN
    RAISE EXCEPTION 'remaining_group_character_did_not_reply';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_group_turn_charges
    WHERE group_id = v_group
      AND group_turn_id = v_group_continue_turn
      AND member_count = 2
      AND cost = 6
      AND status = 'settled'
  ) THEN
    RAISE EXCEPTION 'group_turn_must_charge_all_existing_characters';
  END IF;

  -- The next round-robin slot is the deleted character; it must still reply.
  v_group_deleted_character_turn := public.append_chat_group_mock_turn(
    v_group,
    '70000000-0000-4000-8000-000000000004',
    'The deleted character should still answer in the existing group'
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_group_messages
    WHERE group_id = v_group
      AND turn_id = v_group_deleted_character_turn
      AND speaker_type = 'character'
      AND character_id = v_group_draft
  ) THEN
    RAISE EXCEPTION 'deleted_group_character_must_continue_speaking';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_group_turn_charges
    WHERE group_id = v_group
      AND group_turn_id = v_group_deleted_character_turn
      AND member_count = 2
      AND cost = 6
      AND status = 'settled'
  ) THEN
    RAISE EXCEPTION 'deleted_group_character_must_remain_billable';
  END IF;

  -- Encounter relationship and diary rows are player history and must survive character deletion.
  INSERT INTO public.characters (id, author_id, name, visibility, review_status)
  VALUES (v_encounter_draft, v_user, 'Private draft with encounter history', 'private', 'draft');
  INSERT INTO public.encounter_character_state (id, user_id, character_id, affinity, relationship_stage)
  VALUES (v_encounter_state, v_user, v_encounter_draft, 12, 'acquaintance');
  INSERT INTO public.encounter_diary (id, user_id, character_id, event_type, summary)
  VALUES (v_encounter_diary, v_user, v_encounter_draft, 'interaction', 'Existing encounter memory');
  -- Create the Encounter session while the character is still active. The
  -- player will continue this same session only after the author archives it.
  -- chat_mode is server-managed; use the trusted server role for this fixture,
  -- then restore the simulated player role before exercising the player writer.
  PERFORM pg_catalog.set_config('request.jwt.claim.role', 'service_role', true);
  INSERT INTO public.chat_sessions (id, user_id, character_id, character_name, chat_mode)
  VALUES (v_encounter_session, v_user, v_encounter_draft, 'Private draft with encounter history', 'encounter');
  PERFORM pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_sessions
    WHERE id = v_encounter_session AND chat_mode = 'encounter'
  ) THEN
    RAISE EXCEPTION 'encounter_fixture_must_use_server_managed_encounter_mode';
  END IF;
  INSERT INTO public.encounter_session_lifecycle (
    session_id, user_id, character_id, location_key, schedule_snapshot,
    scheduled_start_at, scheduled_end_at, status
  ) VALUES (
    v_encounter_session, v_user, v_encounter_draft, 'cafe',
    jsonb_build_object('location_key', 'cafe'),
    now() - interval '1 hour', now() + interval '1 hour', 'active'
  );
  v_deleted_at := public.soft_delete_character(v_encounter_draft);
  IF NOT EXISTS (
    SELECT 1 FROM public.characters WHERE id = v_encounter_draft AND deleted_at = v_deleted_at
  ) THEN
    RAISE EXCEPTION 'character_with_encounter_history_must_soft_delete';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.encounter_character_state
    WHERE id = v_encounter_state AND character_id = v_encounter_draft AND affinity = 12
  ) OR NOT EXISTS (
    SELECT 1 FROM public.encounter_diary
    WHERE id = v_encounter_diary AND character_id = v_encounter_draft
      AND summary = 'Existing encounter memory'
  ) THEN
    RAISE EXCEPTION 'encounter_relationship_or_diary_history_was_lost';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_sessions
    WHERE id = v_encounter_session
      AND deleted_at IS NULL
      AND character_snapshot ? 'deletedAt'
  ) THEN
    RAISE EXCEPTION 'existing_encounter_session_snapshot_not_preserved';
  END IF;

  -- Existing Encounter session can still reserve a turn and persist its AI
  -- reply/evidence after character deletion. No new session is created here.
  INSERT INTO public.chat_messages (id, session_id, role, content)
  VALUES (v_encounter_user_message, v_encounter_session, 'user', 'I am continuing our encounter');
  SELECT r.status INTO v_encounter_turn_status
  FROM public.reserve_encounter_chat_turn(
    v_user, v_encounter_turn, v_encounter_session,
    v_encounter_user_message, v_encounter_assistant_message
  ) AS r;
  IF v_encounter_turn_status IS DISTINCT FROM 'reserved' THEN
    RAISE EXCEPTION 'existing_encounter_turn_reservation_failed_after_character_delete';
  END IF;
  INSERT INTO public.chat_messages (id, session_id, role, content)
  VALUES (
    v_encounter_assistant_message, v_encounter_session, 'assistant',
    'I remember our meeting. Let us continue.'
  );
  IF public.settle_chat_turn(v_user, v_encounter_turn, v_encounter_assistant_message)
     IS DISTINCT FROM 'settled' THEN
    RAISE EXCEPTION 'existing_encounter_turn_settlement_failed_after_character_delete';
  END IF;
  v_encounter_evidence := public.record_encounter_session_turn_evidence(
    v_encounter_turn, v_encounter_session, v_user, v_encounter_draft,
    v_encounter_user_message, v_encounter_assistant_message,
    jsonb_build_object('source', 'pr200_disposable_continuation_test')
  );
  IF v_encounter_evidence->>'status' IS DISTINCT FROM 'pending'
     OR NOT EXISTS (
       SELECT 1 FROM public.encounter_session_turns
       WHERE turn_id = v_encounter_turn
         AND session_id = v_encounter_session
         AND turn_number = 1
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.encounter_session_lifecycle
       WHERE session_id = v_encounter_session AND turn_count = 1
     ) THEN
    RAISE EXCEPTION 'existing_encounter_evidence_not_persisted_after_character_delete';
  END IF;

  -- Deletion RPC is idempotent: retries return the original deletion timestamp.
  IF public.soft_delete_character(v_group_draft) IS DISTINCT FROM v_group_deleted_at THEN
    RAISE EXCEPTION 'duplicate_character_delete_did_not_return_original_timestamp';
  END IF;

  -- A truly unused new draft queues both exact asset paths before hard deletion.
  v_avatar_path := v_user::text || '/' || v_asset_draft::text || '/avatar.mp4';
  v_illustration_path := v_user::text || '/' || v_asset_draft::text || '/' || v_asset_file::text || '.webp';
  INSERT INTO public.characters (id, author_id, name, visibility, review_status, avatar_video_path)
  VALUES (v_asset_draft, v_user, 'Private draft with assets', 'private', 'draft', v_avatar_path);
  INSERT INTO public.character_illustrations (character_id, author_id, storage_path, asset_type, sort_order)
  VALUES (v_asset_draft, v_user, v_illustration_path, 'gallery', 1);
  v_deleted_at := public.soft_delete_character(v_asset_draft);
  IF EXISTS (SELECT 1 FROM public.characters WHERE id = v_asset_draft) THEN
    RAISE EXCEPTION 'unused_asset_draft_should_hard_delete';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.character_asset_cleanup_jobs WHERE bucket_id = 'character-avatar-videos' AND object_path = v_avatar_path AND character_id = v_asset_draft) THEN
    RAISE EXCEPTION 'avatar_video_cleanup_job_missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.character_asset_cleanup_jobs WHERE bucket_id = 'character-illustrations' AND object_path = v_illustration_path AND character_id = v_asset_draft) THEN
    RAISE EXCEPTION 'illustration_cleanup_job_missing';
  END IF;

  -- Once queued, neither the avatar nor illustration path can be attached again.
  BEGIN
    INSERT INTO public.characters (id, author_id, name, visibility, review_status, avatar_video_path)
    VALUES (v_asset_draft, v_user, 'Attempted avatar path reuse', 'private', 'draft', v_avatar_path);
    RAISE EXCEPTION 'expected_queued_avatar_path_reuse_rejection';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO public.characters (id, author_id, name, visibility, review_status)
  VALUES (v_asset_draft, v_user, 'Attempted illustration path reuse', 'private', 'draft');
  BEGIN
    INSERT INTO public.character_illustrations (character_id, author_id, storage_path, asset_type, sort_order)
    VALUES (v_asset_draft, v_user, v_illustration_path, 'gallery', 1);
    RAISE EXCEPTION 'expected_queued_illustration_path_reuse_rejection';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  IF has_table_privilege('authenticated', 'public.characters', 'DELETE') THEN
    RAISE EXCEPTION 'authenticated_must_not_directly_delete_characters';
  END IF;
END;
$$;
