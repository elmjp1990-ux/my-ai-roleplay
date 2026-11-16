DO $$
DECLARE
  v_owner uuid := '11111111-1111-4111-8111-111111111111';
  v_author uuid := '22222222-2222-4222-8222-222222222222';
  v_character uuid := '33333333-3333-4333-8333-333333333333';
  v_group uuid;
  v_snapshot jsonb;
  v_session uuid := '44444444-4444-4444-8444-444444444444';
  v_updated_at timestamptz := '2026-11-16 12:00:00+00';
  v_deleted_at timestamptz := now();
  v_private_character uuid := '55555555-5555-4555-8555-555555555555';
  v_active_character uuid := '66666666-6666-4666-8666-666666666666';
  v_single_character uuid := '88888888-8888-4888-8888-888888888888';
  v_single_session uuid := '99999999-9999-4999-8999-999999999999';
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);

  INSERT INTO public.characters(id, author_id, name, gender, age, avatar_url, intro, race, style, tags, visibility, review_status)
  VALUES (
    v_character, v_author, 'Snapshot Hero', 'male', 28, 'https://example.invalid/avatar.jpg',
    'Original intro', 'human', 'warm', '["test"]'::jsonb, 'public', 'draft'
  );
  INSERT INTO public.character_illustrations(character_id, asset_type, storage_path)
  VALUES (v_character, 'primary', v_author::text || '/' || v_character::text || '/portrait.webp');
  INSERT INTO public.character_stories(character_id, opening_message, visibility)
  VALUES (v_character, 'Original opening', 'public');

  v_group := public.create_chat_group(
    'Snapshot group',
    'Original world',
    'shared',
    '[{"name":"Opening scene","description":"Original group opening"}]'::jsonb,
    jsonb_build_array(jsonb_build_object('character_id', v_character::text, 'scene_position', 1))
  );

  SELECT character_snapshot INTO v_snapshot
  FROM public.chat_group_members
  WHERE group_id = v_group AND character_id = v_character;

  IF v_snapshot->>'imagePath' IS DISTINCT FROM v_author::text || '/' || v_character::text || '/portrait.webp' THEN
    RAISE EXCEPTION 'group snapshot did not persist the primary portrait path';
  END IF;
  IF COALESCE(v_snapshot->>'image', '') <> '' THEN
    RAISE EXCEPTION 'group snapshot should not duplicate an embedded avatar when a Storage path exists';
  END IF;
  IF v_snapshot->>'opening' IS DISTINCT FROM 'Original opening'
     OR v_snapshot->>'intro' IS DISTINCT FROM 'Original intro' THEN
    RAISE EXCEPTION 'group snapshot did not preserve the opening and intro';
  END IF;

  INSERT INTO public.chat_sessions(id, user_id, character_id, character_snapshot, updated_at)
  VALUES (
    v_session, v_owner, v_character,
    jsonb_build_object(
      'id', v_character, 'name', 'Snapshot Hero', 'imagePath', v_author::text || '/' || v_character::text || '/portrait.webp',
      'intro', 'Original intro', 'opening', 'Original opening'
    ),
    v_updated_at
  );

  INSERT INTO public.characters(id, author_id, name, visibility, review_status)
  VALUES (v_single_character, v_author, 'Single snapshot hero', 'public', 'draft');
  INSERT INTO public.character_illustrations(character_id, asset_type, storage_path)
  VALUES (v_single_character, 'primary', v_author::text || '/' || v_single_character::text || '/single.webp');
  INSERT INTO public.chat_sessions(id, user_id, character_id, character_snapshot, updated_at)
  VALUES (
    v_single_session, v_owner, v_single_character,
    jsonb_build_object(
      'id', v_single_character, 'name', 'Single snapshot hero',
      'imagePath', v_author::text || '/' || v_single_character::text || '/single.webp'
    ),
    v_updated_at
  );

  PERFORM public.soft_delete_character(v_character);
  PERFORM public.soft_delete_character(v_single_character);

  SELECT character_snapshot INTO v_snapshot
  FROM public.chat_group_members
  WHERE group_id = v_group AND character_id = v_character;
  IF (v_snapshot->>'deletedAt')::timestamptz IS DISTINCT FROM v_deleted_at THEN
    RAISE EXCEPTION 'group snapshot was not marked offline after soft delete';
  END IF;
  IF v_snapshot->>'imagePath' IS DISTINCT FROM v_author::text || '/' || v_character::text || '/portrait.webp'
     OR v_snapshot->>'intro' IS DISTINCT FROM 'Original intro'
     OR v_snapshot->>'opening' IS DISTINCT FROM 'Original opening' THEN
    RAISE EXCEPTION 'soft delete changed original group snapshot content';
  END IF;

  SELECT character_snapshot INTO v_snapshot
  FROM public.chat_sessions WHERE id = v_session;
  IF (v_snapshot->>'deletedAt')::timestamptz IS DISTINCT FROM v_deleted_at THEN
    RAISE EXCEPTION 'single-chat snapshot was not marked offline after soft delete';
  END IF;
  IF v_snapshot->>'imagePath' IS DISTINCT FROM v_author::text || '/' || v_character::text || '/portrait.webp'
     OR v_snapshot->>'intro' IS DISTINCT FROM 'Original intro'
     OR v_snapshot->>'opening' IS DISTINCT FROM 'Original opening' THEN
    RAISE EXCEPTION 'soft delete changed original single-chat snapshot content';
  END IF;
  IF (SELECT updated_at FROM public.chat_sessions WHERE id = v_session) IS DISTINCT FROM v_updated_at
     OR (SELECT updated_at FROM public.chat_sessions WHERE id = v_single_session) IS DISTINCT FROM v_updated_at THEN
    RAISE EXCEPTION 'soft_delete_character changed the chat sync version';
  END IF;

  BEGIN
    PERFORM public.create_chat_group(
      'Should fail for deleted character', 'World', 'shared',
      '[{"name":"Scene","description":"Opening"}]'::jsonb,
      jsonb_build_array(jsonb_build_object('character_id', v_character::text, 'scene_position', 1))
    );
    RAISE EXCEPTION 'new group unexpectedly accepted a soft-deleted character';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  INSERT INTO public.characters(id, author_id, name, visibility)
  VALUES (v_private_character, v_author, 'Private character', 'private');
  BEGIN
    PERFORM public.create_chat_group(
      'Should fail for private character', 'World', 'shared',
      '[{"name":"Scene","description":"Opening"}]'::jsonb,
      jsonb_build_array(jsonb_build_object('character_id', v_private_character::text, 'scene_position', 1))
    );
    RAISE EXCEPTION 'new group unexpectedly accepted a private character';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  INSERT INTO public.characters(id, author_id, name, visibility)
  VALUES (v_active_character, v_author, 'Active public character', 'public');
  INSERT INTO public.account_deletion_requests(user_id) VALUES (v_owner);
  BEGIN
    PERFORM public.create_chat_group(
      'Should fail for pending account deletion', 'World', 'shared',
      '[{"name":"Scene","description":"Opening"}]'::jsonb,
      jsonb_build_array(jsonb_build_object('character_id', v_active_character::text, 'scene_position', 1))
    );
    RAISE EXCEPTION 'new group unexpectedly accepted an account pending deletion';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  DELETE FROM public.account_deletion_requests WHERE user_id = v_owner;
END;
$$;

INSERT INTO storage.objects(bucket_id, name)
VALUES
  ('character-illustrations', '22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/portrait.webp'),
  ('character-illustrations', '22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/other.webp'),
  ('character-illustrations', '22222222-2222-4222-8222-222222222222/88888888-8888-4888-8888-888888888888/single.webp'),
  ('character-illustrations', '22222222-2222-4222-8222-222222222222/88888888-8888-4888-8888-888888888888/other.webp');

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', false);
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM storage.objects
    WHERE name = '22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/portrait.webp'
  ) THEN
    RAISE EXCEPTION 'group owner cannot read the exact portrait path in the trusted snapshot';
  END IF;
  IF EXISTS (
    SELECT 1 FROM storage.objects
    WHERE name = '22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/other.webp'
  ) THEN
    RAISE EXCEPTION 'group owner received access to a non-snapshotted sibling object';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM storage.objects
    WHERE name = '22222222-2222-4222-8222-222222222222/88888888-8888-4888-8888-888888888888/single.webp'
  ) THEN
    RAISE EXCEPTION 'single-chat owner cannot read the exact portrait path in the trusted snapshot';
  END IF;
  IF EXISTS (
    SELECT 1 FROM storage.objects
    WHERE name = '22222222-2222-4222-8222-222222222222/88888888-8888-4888-8888-888888888888/other.webp'
  ) THEN
    RAISE EXCEPTION 'single-chat owner received access to a non-snapshotted sibling object';
  END IF;
END;
$$;
RESET ROLE;

INSERT INTO public.characters(id, author_id, name, visibility, is_nsfw)
VALUES ('77777777-7777-4777-8777-777777777777', '22222222-2222-4222-8222-222222222222', 'Public asset', 'public', false);
INSERT INTO public.character_illustrations(character_id, asset_type, storage_path)
VALUES ('77777777-7777-4777-8777-777777777777', 'primary', '22222222-2222-4222-8222-222222222222/77777777-7777-4777-8777-777777777777/public.webp');
INSERT INTO storage.objects(bucket_id, name)
VALUES ('character-illustrations', '22222222-2222-4222-8222-222222222222/77777777-7777-4777-8777-777777777777/public.webp');

SET ROLE anon;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM storage.objects
    WHERE name = '22222222-2222-4222-8222-222222222222/77777777-7777-4777-8777-777777777777/public.webp'
  ) THEN
    RAISE EXCEPTION 'original public non-NSFW illustration access was not preserved';
  END IF;
END;
$$;
RESET ROLE;
