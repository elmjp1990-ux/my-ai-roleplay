-- Effective Storage RLS behavior for character asset preservation.
-- Executed only inside replay-account-deletion-release-migration.sql's outer
-- disposable transaction. Fixtures are rolled back by that outer transaction.
\set ON_ERROR_STOP on

DO $fixture$
DECLARE
  v_author uuid := '10000000-0000-4000-8000-000000000040';
  v_character uuid := '20000000-0000-4000-8000-000000000040';
BEGIN
  INSERT INTO auth.users (id) VALUES (v_author) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.profiles (id, handle, nickname)
  VALUES (v_author, 'pr200-storage-freeze-author', 'PR200 Storage Fixture')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.characters (
    id, author_id, name, visibility, review_status, rights_confirmed
  ) VALUES (
    v_character, v_author, 'PR200 storage freeze fixture', 'public', 'approved', true
  );

  INSERT INTO storage.buckets (id, name, public)
  VALUES
    ('character-illustrations', 'character-illustrations', false),
    ('character-avatar-videos', 'character-avatar-videos', false)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO storage.objects (bucket_id, name) VALUES
    (
      'character-illustrations',
      '10000000-0000-4000-8000-000000000040/20000000-0000-4000-8000-000000000040/30000000-0000-4000-8000-000000000040.jpg'
    ),
    (
      'character-avatar-videos',
      '10000000-0000-4000-8000-000000000040/40000000-0000-4000-8000-000000000040.mp4'
    );
END;
$fixture$;

-- Match the Storage helper used by the pre-existing video UPDATE policy.
-- The synthetic platform shim omits this platform-owned helper.
CREATE OR REPLACE FUNCTION storage.foldername(name text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $function$
  SELECT pg_catalog.string_to_array(name, '/');
$function$;

-- The disposable Storage shim grants SELECT only by default. Grant mutations
-- here so this test isolates row-policy behavior, not platform table grants.
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated;

SELECT pg_catalog.set_config('request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000040', true);
SELECT pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
SELECT pg_catalog.set_config('request.jwt.claims',
  '{"sub":"10000000-0000-4000-8000-000000000040","role":"authenticated"}', true);

-- Assert the test identity, account state, and character ownership fixture
-- before attributing any denied Storage update to the policy under test.
DO $precheck$
BEGIN
  IF auth.uid() IS DISTINCT FROM '10000000-0000-4000-8000-000000000040'::uuid THEN
    RAISE EXCEPTION 'storage_fixture_jwt_subject_not_set';
  END IF;
  IF public.account_is_active() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'storage_fixture_account_must_be_active_before_request';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.characters
    WHERE id = '20000000-0000-4000-8000-000000000040'
      AND author_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'storage_fixture_character_not_visible_to_owner';
  END IF;
END;
$precheck$;

-- While active, owner update remains available for both asset types.
SET LOCAL ROLE authenticated;
DO $active_owner$
DECLARE
  v_rows integer;
  v_path text := '10000000-0000-4000-8000-000000000040/20000000-0000-4000-8000-000000000040/30000000-0000-4000-8000-000000000040.jpg';
  v_matches boolean;
BEGIN
  IF NOT has_table_privilege(current_user, 'storage.objects', 'UPDATE') THEN
    RAISE EXCEPTION 'authenticated_storage_update_grant_missing';
  END IF;
  v_matches := split_part(v_path, '/', 1) = auth.uid()::text
    AND public.account_is_active()
    AND EXISTS (
      SELECT 1 FROM public.characters c
      WHERE c.id::text = split_part(v_path, '/', 2)
        AND c.author_id = auth.uid()
    );
  IF NOT v_matches THEN
    RAISE EXCEPTION 'active_owner_storage_update_predicate_false: uid %, active %, path %, character_exists %',
      auth.uid(), public.account_is_active(),
      split_part(v_path, '/', 1) = auth.uid()::text,
      EXISTS (SELECT 1 FROM public.characters c
        WHERE c.id::text = split_part(v_path, '/', 2) AND c.author_id = auth.uid());
  END IF;

  UPDATE storage.objects SET name = name
  WHERE bucket_id = 'character-illustrations'
    AND name = v_path;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN RAISE EXCEPTION 'active_owner_must_retain_illustration_storage_update: rowcount %', v_rows; END IF;

  UPDATE storage.objects SET name = name
  WHERE bucket_id = 'character-avatar-videos'
    AND name = '10000000-0000-4000-8000-000000000040/40000000-0000-4000-8000-000000000040.mp4';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN RAISE EXCEPTION 'active_owner_must_retain_video_storage_update'; END IF;
END;
$active_owner$;
RESET ROLE;

-- A pending account must not mutate/delete either asset via direct Storage RLS.
INSERT INTO public.account_deletion_requests (user_id, requested_at, scheduled_for)
VALUES (
  '10000000-0000-4000-8000-000000000040',
  clock_timestamp(), clock_timestamp() + interval '5 minutes'
);

SET LOCAL ROLE authenticated;
DO $pending_owner$
DECLARE v_rows integer;
BEGIN
  UPDATE storage.objects SET name = name
  WHERE bucket_id = 'character-illustrations'
    AND name = '10000000-0000-4000-8000-000000000040/20000000-0000-4000-8000-000000000040/30000000-0000-4000-8000-000000000040.jpg';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_owner_illustration_storage_update_not_blocked'; END IF;

  DELETE FROM storage.objects
  WHERE bucket_id = 'character-illustrations'
    AND name = '10000000-0000-4000-8000-000000000040/20000000-0000-4000-8000-000000000040/30000000-0000-4000-8000-000000000040.jpg';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_owner_illustration_storage_delete_not_blocked'; END IF;

  UPDATE storage.objects SET name = name
  WHERE bucket_id = 'character-avatar-videos'
    AND name = '10000000-0000-4000-8000-000000000040/40000000-0000-4000-8000-000000000040.mp4';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_owner_video_storage_update_not_blocked'; END IF;

  DELETE FROM storage.objects
  WHERE bucket_id = 'character-avatar-videos'
    AND name = '10000000-0000-4000-8000-000000000040/40000000-0000-4000-8000-000000000040.mp4';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_owner_video_storage_delete_not_blocked'; END IF;
END;
$pending_owner$;
RESET ROLE;

-- A stale JWT must also fail closed after Auth user deletion.
DELETE FROM auth.users
WHERE id = '10000000-0000-4000-8000-000000000040';

SET LOCAL ROLE authenticated;
DO $stale_jwt$
DECLARE v_rows integer;
BEGIN
  IF public.account_is_active() IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'deleted_auth_user_must_not_be_active';
  END IF;

  DELETE FROM storage.objects
  WHERE bucket_id = 'character-avatar-videos'
    AND name = '10000000-0000-4000-8000-000000000040/40000000-0000-4000-8000-000000000040.mp4';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'stale_jwt_video_storage_delete_not_blocked'; END IF;

  DELETE FROM storage.objects
  WHERE bucket_id = 'character-illustrations'
    AND name = '10000000-0000-4000-8000-000000000040/20000000-0000-4000-8000-000000000040/30000000-0000-4000-8000-000000000040.jpg';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'stale_jwt_illustration_storage_delete_not_blocked'; END IF;
END;
$stale_jwt$;
RESET ROLE;
