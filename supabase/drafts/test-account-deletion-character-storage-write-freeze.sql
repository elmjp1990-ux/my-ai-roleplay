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

  INSERT INTO storage.objects (
    id, bucket_id, name, owner, owner_id, metadata
  ) VALUES
    (
      '30000000-0000-4000-8000-000000000040',
      'character-illustrations',
      '10000000-0000-4000-8000-000000000040/20000000-0000-4000-8000-000000000040/30000000-0000-4000-8000-000000000040.jpg',
      v_author, v_author::text, '{"mimetype":"image/jpeg","size":12}'::jsonb
    ),
    (
      '40000000-0000-4000-8000-000000000040',
      'character-avatar-videos',
      '10000000-0000-4000-8000-000000000040/40000000-0000-4000-8000-000000000040.mp4',
      v_author, v_author::text, '{"mimetype":"video/mp4","size":12}'::jsonb
    );
END;
$fixture$;

SELECT pg_catalog.set_config('request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000040', true);
SELECT pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
SELECT pg_catalog.set_config('request.jwt.claims',
  '{"sub":"10000000-0000-4000-8000-000000000040","role":"authenticated"}', true);

-- While active, owner update remains available.
SET LOCAL ROLE authenticated;
DO $active_owner$
DECLARE v_rows integer;
BEGIN
  UPDATE storage.objects
  SET metadata = metadata || '{"active_update":true}'::jsonb
  WHERE id = '30000000-0000-4000-8000-000000000040';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN RAISE EXCEPTION 'active_owner_must_retain_illustration_storage_update'; END IF;
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
  UPDATE storage.objects
  SET metadata = metadata || '{"pending_update":true}'::jsonb
  WHERE id = '30000000-0000-4000-8000-000000000040';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_owner_illustration_storage_update_not_blocked'; END IF;

  DELETE FROM storage.objects
  WHERE id = '30000000-0000-4000-8000-000000000040';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_owner_illustration_storage_delete_not_blocked'; END IF;

  UPDATE storage.objects
  SET metadata = metadata || '{"pending_update":true}'::jsonb
  WHERE id = '40000000-0000-4000-8000-000000000040';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'pending_owner_video_storage_update_not_blocked'; END IF;

  DELETE FROM storage.objects
  WHERE id = '40000000-0000-4000-8000-000000000040';
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
  WHERE id = '40000000-0000-4000-8000-000000000040';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'stale_jwt_video_storage_delete_not_blocked'; END IF;

  DELETE FROM storage.objects
  WHERE id = '30000000-0000-4000-8000-000000000040';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'stale_jwt_illustration_storage_delete_not_blocked'; END IF;
END;
$stale_jwt$;
RESET ROLE;
