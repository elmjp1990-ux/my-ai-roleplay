-- DRAFT ONLY — behavior test for archived-group memory photo reads.
-- Run inside replay-local-security-drafts.sql's disposable transaction, then rollback.

-- Seed fixture as the disposable database owner before switching to authenticated.
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

  RAISE NOTICE 'storage_objects_seeded=%', (
    SELECT pg_catalog.count(*) FROM storage.objects
    WHERE name IN (v_archived_path, v_deleted_path)
  );
  RAISE NOTICE 'storage_seed_rows=%', (
    SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('bucket_id', bucket_id, 'name', name))
    FROM storage.objects WHERE name IN (v_archived_path, v_deleted_path)
  );

  GRANT USAGE ON SCHEMA storage TO authenticated;
  ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
  GRANT SELECT ON storage.objects TO authenticated;
  DROP POLICY IF EXISTS test_debug_storage_allow ON storage.objects;
  CREATE POLICY test_debug_storage_allow
    ON storage.objects FOR SELECT TO authenticated USING (true);
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
SELECT pg_catalog.count(*) AS debug_allow_policy_rows FROM storage.objects
WHERE name LIKE '90000000-0000-4000-8000-000000000001/group/%';
SELECT o.name,
  o.bucket_id = 'personax-memory-photos' AS bucket_matches,
  pg_catalog.split_part(o.name, '/', 1) = auth.uid()::text AS owner_matches,
  o.name ~* (
    '^' || auth.uid()::text ||
    '/(single|group)/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
    '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)'
  ) AS path_matches,
  EXISTS (
    SELECT 1 FROM public.chat_memory_photos p
    WHERE p.storage_path = o.name
      AND p.owner_id = auth.uid()
      AND p.deleted_at IS NULL
      AND p.chat_type = 'group'
      AND EXISTS (
        SELECT 1 FROM public.chat_groups g
        WHERE g.id = p.group_id
          AND g.owner_id = auth.uid()
          AND g.deleted_at IS NULL
      )
  ) AS metadata_matches
FROM storage.objects o
WHERE o.name LIKE '90000000-0000-4000-8000-000000000001/group/%';
RESET ROLE;
DROP POLICY test_debug_storage_allow ON storage.objects;
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

  RAISE NOTICE 'storage_policy_inputs=%', pg_catalog.jsonb_build_object(
    'auth_uid', auth.uid(),
    'auth_role', auth.role(),
    'current_user', current_user,
    'owner_prefix_matches', pg_catalog.split_part(v_archived_path, '/', 1) = auth.uid()::text,
    'bucket_id_literal_matches', 'personax-memory-photos' = 'personax-memory-photos',
    'policy_qual', (
      SELECT p.qual FROM pg_catalog.pg_policies p
      WHERE p.schemaname = 'storage'
        AND p.tablename = 'objects'
        AND p.policyname = 'memory_photo_objects_select_owner'
    ),
    'all_policies', (
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'name', p.policyname, 'permissive', p.permissive,
        'roles', p.roles, 'command', p.cmd, 'qual', p.qual
      )) FROM pg_catalog.pg_policies p
      WHERE p.schemaname = 'storage' AND p.tablename = 'objects'
    ),
    'rls_enabled', (
      SELECT c.relrowsecurity FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'storage' AND c.relname = 'objects'
    ),
    'rls_forced', (
      SELECT c.relforcerowsecurity FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'storage' AND c.relname = 'objects'
    ),
    'select_privilege', pg_catalog.has_table_privilege(current_user, 'storage.objects', 'SELECT'),
    'archived_path_matches', v_archived_path ~* (
      '^' || auth.uid()::text ||
      '/(single|group)/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
      '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$'
    ),
    'archived_photo_visible', EXISTS (
      SELECT 1 FROM public.chat_memory_photos p
      WHERE p.storage_path = v_archived_path
        AND p.owner_id = auth.uid()
        AND p.deleted_at IS NULL
        AND p.chat_type = 'group'
        AND EXISTS (
          SELECT 1 FROM public.chat_groups g
          WHERE g.id = p.group_id
            AND g.owner_id = auth.uid()
            AND g.deleted_at IS NULL
        )
    ),
    'archived_group_visible', EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = v_archived_group
        AND g.owner_id = auth.uid()
        AND g.deleted_at IS NULL
    )
  );

  SELECT pg_catalog.count(*)::integer INTO v_object_count
  FROM storage.objects AS objects
  WHERE objects.name IN (v_archived_path, v_deleted_path);
  IF v_object_count <> 1 THEN
    RAISE EXCEPTION 'archived_group_storage_object_must_remain_readable_and_deleted_group_hidden: %', v_object_count;
  END IF;
END;
$photo_assert$;

RESET ROLE;
