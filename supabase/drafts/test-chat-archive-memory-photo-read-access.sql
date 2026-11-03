-- DRAFT ONLY — behavior test for archived-group memory photo reads.
-- Run inside replay-local-security-drafts.sql's disposable transaction, then rollback.
DO $photo_seed$
DECLARE
  v_owner uuid := '90000000-0000-4000-8000-000000000001';
  v_archived_group uuid := '60000000-0000-4000-8000-000000000001';
  v_deleted_group uuid := '60000000-0000-4000-8000-000000000002';
  v_archived_photo uuid := '70000000-0000-4000-8000-000000000001';
  v_deleted_photo uuid := '70000000-0000-4000-8000-000000000002';
  v_archived_path text;
  v_deleted_path text;
BEGIN
  v_archived_path := v_owner::text || '/group/' || v_archived_group::text || '/' || v_archived_photo::text || '.jpg';
  v_deleted_path := v_owner::text || '/group/' || v_deleted_group::text || '/' || v_deleted_photo::text || '.jpg';

  INSERT INTO auth.users (id) VALUES (v_owner) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.profiles (id, handle, nickname)
  VALUES (v_owner, 'pr200-archived-photo-reader', 'Archived Photo Reader')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.chat_groups (
    id, owner_id, name, scene_mode, archived_at, deleted_at
  ) VALUES
    (v_archived_group, v_owner, 'Archived Photo Group', 'shared', pg_catalog.clock_timestamp(), NULL),
    (v_deleted_group, v_owner, 'Deleted Photo Group', 'shared', NULL, pg_catalog.clock_timestamp());

  INSERT INTO public.chat_memory_photos (
    id, owner_id, chat_type, group_id, storage_path, caption
  ) VALUES
    (v_archived_photo, v_owner, 'group', v_archived_group, v_archived_path, 'Archived group photo'),
    (v_deleted_photo, v_owner, 'group', v_deleted_group, v_deleted_path, 'Deleted group photo');

  INSERT INTO storage.objects (bucket_id, name)
  VALUES ('personax-memory-photos', v_archived_path),
         ('personax-memory-photos', v_deleted_path);

  GRANT USAGE ON SCHEMA storage TO authenticated;
  ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
  GRANT SELECT ON storage.objects TO authenticated;
END;
$photo_seed$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '90000000-0000-4000-8000-000000000001', true);
SELECT pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
SELECT pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"90000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);

DO $photo_assert$
DECLARE
  v_archived_photo uuid := '70000000-0000-4000-8000-000000000001';
  v_deleted_photo uuid := '70000000-0000-4000-8000-000000000002';
  v_archived_group uuid := '60000000-0000-4000-8000-000000000001';
  v_deleted_group uuid := '60000000-0000-4000-8000-000000000002';
  v_archived_path text := '90000000-0000-4000-8000-000000000001/group/60000000-0000-4000-8000-000000000001/70000000-0000-4000-8000-000000000001.jpg';
  v_deleted_path text := '90000000-0000-4000-8000-000000000001/group/60000000-0000-4000-8000-000000000002/70000000-0000-4000-8000-000000000002.jpg';
  v_photo_count integer;
  v_object_count integer;
BEGIN
  SELECT pg_catalog.count(*)::integer INTO v_photo_count
  FROM public.chat_memory_photos
  WHERE id IN (v_archived_photo, v_deleted_photo);
  IF v_photo_count <> 1 THEN
    RAISE EXCEPTION 'archived_group_photo_metadata_must_remain_readable_and_deleted_group_hidden: %', v_photo_count;
  END IF;

  SELECT pg_catalog.count(*)::integer INTO v_object_count
  FROM storage.objects
  WHERE name IN (v_archived_path, v_deleted_path);
  IF v_object_count <> 1 THEN
    RAISE EXCEPTION 'archived_group_storage_object_must_remain_readable_and_deleted_group_hidden: %', v_object_count;
  END IF;
END;
$photo_assert$;

RESET ROLE;
