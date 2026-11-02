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
  v_asset_file uuid := '30000000-0000-4000-8000-000000000001';
  v_story uuid := '40000000-0000-4000-8000-000000000001';
  v_deleted_at timestamptz;
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

  -- A formerly-public row already private before rollout has neither proof of origin nor publication marker.
  -- It still fails closed because no post-installation INSERT marker exists.
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
  INSERT INTO public.chat_sessions (user_id, character_id, character_name)
  VALUES (v_user, v_chat_draft, 'Private draft with chat history');
  v_deleted_at := public.soft_delete_character(v_chat_draft);
  IF NOT EXISTS (SELECT 1 FROM public.characters WHERE id = v_chat_draft AND deleted_at = v_deleted_at) THEN
    RAISE EXCEPTION 'character_with_chat_history_must_soft_delete';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chat_sessions WHERE character_id = v_chat_draft AND character_snapshot ? 'deletedAt') THEN
    RAISE EXCEPTION 'existing_chat_session_snapshot_not_preserved';
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
