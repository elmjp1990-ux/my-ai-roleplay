-- DRAFT ONLY — disposable PostgreSQL behavior test, executed inside the
-- PR #200 replay transaction. This verifies effective RLS as authenticated,
-- not merely policy catalog entries. All fixture changes are rolled back.
\set ON_ERROR_STOP on

BEGIN;

DO $fixture$
DECLARE
  v_author uuid := '10000000-0000-4000-8000-000000000030';
  v_character uuid := '20000000-0000-4000-8000-000000000030';
BEGIN
  INSERT INTO auth.users (id) VALUES (v_author) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.profiles (id, handle, nickname)
  VALUES (v_author, 'pr200-child-rls-author', 'PR200 RLS Fixture')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.characters (
    id, author_id, name, visibility, review_status, rights_confirmed
  ) VALUES (
    v_character, v_author, 'PR200 child RLS fixture', 'public', 'approved', true
  );

  INSERT INTO public.character_private_info (
    character_id, author_id, private_info
  ) VALUES (
    v_character, v_author, 'private fixture value'
  );
  INSERT INTO public.character_schedule_descriptions (
    character_id, author_id, description
  ) VALUES (
    v_character, v_author, 'schedule description fixture'
  );
  INSERT INTO public.character_illustrations (
    id, character_id, author_id, storage_path, asset_type, sort_order
  ) VALUES (
    '30000000-0000-4000-8000-000000000030',
    v_character, v_author,
    '10000000-0000-4000-8000-000000000030/20000000-0000-4000-8000-000000000030/rls-fixture.jpg',
    'primary', 0
  );
END;
$fixture$;

-- A normal active author can still read all three owned child resources.
SELECT pg_catalog.set_config('request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000030', true);
SELECT pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
SELECT pg_catalog.set_config('request.jwt.claims',
  '{"sub":"10000000-0000-4000-8000-000000000030","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;

DO $active_access$
BEGIN
  IF (SELECT count(*) FROM public.character_private_info
      WHERE character_id = '20000000-0000-4000-8000-000000000030') <> 1
     OR (SELECT count(*) FROM public.character_schedule_descriptions
         WHERE character_id = '20000000-0000-4000-8000-000000000030') <> 1
     OR (SELECT count(*) FROM public.character_illustrations
         WHERE character_id = '20000000-0000-4000-8000-000000000030') <> 1 THEN
    RAISE EXCEPTION 'active_author_must_retain_owned_child_read_access';
  END IF;
END;
$active_access$;

RESET ROLE;

-- A pending deletion request must freeze all three tables immediately.
INSERT INTO public.account_deletion_requests (user_id, requested_at, scheduled_for)
VALUES (
  '10000000-0000-4000-8000-000000000030',
  clock_timestamp(), clock_timestamp() + interval '5 minutes'
);

SET LOCAL ROLE authenticated;

DO $pending_freeze$
DECLARE
  v_rows integer;
  v_insert_denied boolean;
BEGIN
  IF (SELECT count(*) FROM public.character_private_info
      WHERE character_id = '20000000-0000-4000-8000-000000000030') <> 0
     OR (SELECT count(*) FROM public.character_schedule_descriptions
         WHERE character_id = '20000000-0000-4000-8000-000000000030') <> 0
     OR (SELECT count(*) FROM public.character_illustrations
         WHERE character_id = '20000000-0000-4000-8000-000000000030') <> 0 THEN
    RAISE EXCEPTION 'pending_author_must_not_read_any_character_child_data';
  END IF;

  UPDATE public.character_private_info
  SET private_info = 'must not update'
  WHERE character_id = '20000000-0000-4000-8000-000000000030';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_author_private_info_update_was_not_frozen'; END IF;

  DELETE FROM public.character_private_info
  WHERE character_id = '20000000-0000-4000-8000-000000000030';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_author_private_info_delete_was_not_frozen'; END IF;

  UPDATE public.character_schedule_descriptions
  SET description = 'must not update'
  WHERE character_id = '20000000-0000-4000-8000-000000000030';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_author_schedule_description_update_was_not_frozen'; END IF;

  DELETE FROM public.character_schedule_descriptions
  WHERE character_id = '20000000-0000-4000-8000-000000000030';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_author_schedule_description_delete_was_not_frozen'; END IF;

  UPDATE public.character_illustrations
  SET sort_order = 99
  WHERE id = '30000000-0000-4000-8000-000000000030';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_author_illustration_update_was_not_frozen'; END IF;

  DELETE FROM public.character_illustrations
  WHERE id = '30000000-0000-4000-8000-000000000030';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_author_illustration_delete_was_not_frozen'; END IF;

  BEGIN
    INSERT INTO public.character_private_info (character_id, author_id, private_info)
    VALUES ('20000000-0000-4000-8000-000000000030',
            '10000000-0000-4000-8000-000000000030', 'blocked');
  EXCEPTION WHEN insufficient_privilege THEN
    v_insert_denied := true;
  END;
  IF NOT COALESCE(v_insert_denied, false) THEN
    RAISE EXCEPTION 'pending_author_private_info_insert_was_not_frozen';
  END IF;

  v_insert_denied := false;
  BEGIN
    INSERT INTO public.character_schedule_descriptions (character_id, author_id, description)
    VALUES ('20000000-0000-4000-8000-000000000030',
            '10000000-0000-4000-8000-000000000030', 'blocked');
  EXCEPTION WHEN insufficient_privilege THEN
    v_insert_denied := true;
  END;
  IF NOT COALESCE(v_insert_denied, false) THEN
    RAISE EXCEPTION 'pending_author_schedule_description_insert_was_not_frozen';
  END IF;

  v_insert_denied := false;
  BEGIN
    INSERT INTO public.character_illustrations (
      id, character_id, author_id, storage_path, asset_type, sort_order
    ) VALUES (
      '30000000-0000-4000-8000-000000000031',
      '20000000-0000-4000-8000-000000000030',
      '10000000-0000-4000-8000-000000000030',
      '10000000-0000-4000-8000-000000000030/20000000-0000-4000-8000-000000000030/blocked.jpg',
      'gallery', 1
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_insert_denied := true;
  END;
  IF NOT COALESCE(v_insert_denied, false) THEN
    RAISE EXCEPTION 'pending_author_illustration_insert_was_not_frozen';
  END IF;
END;
$pending_freeze$;

RESET ROLE;

-- Simulate Auth Admin deletion while retaining the JWT claims. account_is_active
-- must fail closed even though the deletion-request row cascades away.
DELETE FROM auth.users
WHERE id = '10000000-0000-4000-8000-000000000030';

SET LOCAL ROLE authenticated;

DO $stale_jwt$
DECLARE
  v_rows integer;
  v_insert_denied boolean := false;
BEGIN
  IF public.account_is_active() IS DISTINCT FROM false
     OR (SELECT count(*) FROM public.character_private_info
         WHERE character_id = '20000000-0000-4000-8000-000000000030') <> 0
     OR (SELECT count(*) FROM public.character_schedule_descriptions
         WHERE character_id = '20000000-0000-4000-8000-000000000030') <> 0
     OR (SELECT count(*) FROM public.character_illustrations
         WHERE id = '30000000-0000-4000-8000-000000000030') <> 0 THEN
    RAISE EXCEPTION 'deleted_auth_user_stale_jwt_must_not_read_character_child_data';
  END IF;

  UPDATE public.character_private_info
  SET private_info = 'stale JWT update'
  WHERE character_id = '20000000-0000-4000-8000-000000000030';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'stale_jwt_private_info_update_was_not_frozen'; END IF;

  BEGIN
    INSERT INTO public.character_private_info (character_id, author_id, private_info)
    VALUES ('20000000-0000-4000-8000-000000000030',
            '10000000-0000-4000-8000-000000000030', 'stale JWT insert');
  EXCEPTION WHEN insufficient_privilege THEN
    v_insert_denied := true;
  END;
  IF NOT v_insert_denied THEN
    RAISE EXCEPTION 'stale_jwt_private_info_insert_was_not_frozen';
  END IF;
END;
$stale_jwt$;

RESET ROLE;
ROLLBACK;
