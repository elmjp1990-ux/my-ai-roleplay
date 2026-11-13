do $$
declare
  v_characters integer;
  v_metadata integer;
  v_objects integer;
  v_current integer;
  v_historical integer;
  v_historical_objects integer;
  v_total_cleared integer;
  v_deleted_untouched integer;
begin
  select count(*) into v_characters
  from public.characters
  where id between '20000000-0000-4000-8000-000000000001'::uuid
              and '20000000-0000-4000-8000-000000000008'::uuid
    and avatar_url is null;
  select count(*) into v_metadata
  from public.character_illustrations
  where character_id between '20000000-0000-4000-8000-000000000001'::uuid
                         and '20000000-0000-4000-8000-000000000008'::uuid
    and asset_type = 'primary' and sort_order = 0;
  select count(*) into v_objects
  from storage.objects
  where bucket_id = 'character-illustrations'
    and name like '10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-%';
  select count(*) into v_current
  from public.chat_sessions
  where id::text like '30000000-0000-4000-8000-%'
    and character_snapshot->>'image' = ''
    and character_snapshot->>'imagePath' is not null;
  select count(*) into v_historical
  from public.chat_sessions
  where id::text like '40000000-0000-4000-8000-%'
    and character_snapshot->>'image' = ''
    and character_snapshot->>'imagePath' is not null;
  select count(*) into v_historical_objects
  from storage.objects
  where bucket_id = 'character-illustrations'
    and name like '10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-%'
    and name not in (select storage_path from public.character_illustrations);
  select count(*) into v_total_cleared
  from public.chat_sessions
  where (id::text like '30000000-0000-4000-8000-%' or id::text like '40000000-0000-4000-8000-%')
    and character_snapshot->>'image' = '';

  if v_characters <> 8 then raise exception 'Expected 8 cleared character avatars, got %', v_characters; end if;
  if v_metadata <> 8 then raise exception 'Expected 8 primary metadata rows, got %', v_metadata; end if;
  if v_objects <> 21 then raise exception 'Expected 21 Storage objects (8 primary + 13 historical), got %', v_objects; end if;
  if v_current <> 74 then raise exception 'Expected 74 pathified snapshots, got %', v_current; end if;
  if v_historical <> 13 then raise exception 'Expected 13 historical snapshots with preserved image paths, got %', v_historical; end if;
  if v_historical_objects <> 13 then raise exception 'Expected 13 historical Storage objects, got %', v_historical_objects; end if;
  if v_total_cleared <> 87 then raise exception 'Expected 87 total snapshot clears, got %', v_total_cleared; end if;

  select count(*) into v_deleted_untouched
  from public.chat_sessions
  where id = '50000000-0000-4000-8000-000000000001'::uuid
    and deleted_at is not null
    and character_snapshot->>'image' like 'data:image/%'
    and character_snapshot->>'imagePath' is null;
  if v_deleted_untouched <> 1 then
    raise exception 'Deleted chat snapshot must remain unchanged and unmigrated, got %', v_deleted_untouched;
  end if;
end;
$$;

select
  (select count(*) from public.character_illustrations where asset_type = 'primary'
    and character_id between '20000000-0000-4000-8000-000000000001'::uuid
                         and '20000000-0000-4000-8000-000000000008'::uuid) as primary_metadata,
  (select count(*) from storage.objects where bucket_id = 'character-illustrations'
    and name like '10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-%') as storage_objects,
  (select count(*) from public.chat_sessions where id::text like '30000000-0000-4000-8000-%'
    and character_snapshot->>'imagePath' is not null and character_snapshot->>'image' = '') as pathified_snapshots,
  (select count(*) from public.chat_sessions where id::text like '40000000-0000-4000-8000-%'
    and character_snapshot->>'image' = '' and character_snapshot->>'imagePath' is not null) as historical_pathified;

-- Exercise the actual Storage RLS policy as an authenticated chat owner and outsider.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
SELECT pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
SELECT pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);

DO $storage_owner_assert$
DECLARE
  v_primary_path text;
  v_historical_path text;
  v_unreferenced_path text :=
    '10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000099.png';
  v_count integer;
BEGIN
  SELECT storage_path INTO v_primary_path
  FROM public.character_illustrations
  WHERE character_id = '20000000-0000-4000-8000-000000000001'::uuid
    AND asset_type = 'primary' AND sort_order = 0;
  IF v_primary_path IS NULL THEN
    RAISE EXCEPTION 'owner cannot read primary illustration metadata';
  END IF;

  SELECT character_snapshot->>'imagePath' INTO v_historical_path
  FROM public.chat_sessions
  WHERE id = '40000000-0000-4000-8000-000000000001'::uuid
    AND deleted_at IS NULL;
  IF v_historical_path IS NULL THEN
    RAISE EXCEPTION 'owner cannot read historical snapshot path';
  END IF;

  SELECT count(*) INTO v_count
  FROM storage.objects
  WHERE bucket_id = 'character-illustrations' AND name = v_primary_path;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'owner must read exact primary object, got %', v_count;
  END IF;

  SELECT count(*) INTO v_count
  FROM storage.objects
  WHERE bucket_id = 'character-illustrations' AND name = v_historical_path;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'owner must read exact historical snapshot object, got %', v_count;
  END IF;

  SELECT count(*) INTO v_count
  FROM storage.objects
  WHERE bucket_id = 'character-illustrations' AND name = v_unreferenced_path;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'unreferenced object must not be readable, got %', v_count;
  END IF;

  PERFORM pg_catalog.set_config('test.legacy_image_historical_path', v_historical_path, true);
END;
$storage_owner_assert$;

SELECT pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
SELECT pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
SELECT pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"10000000-0000-4000-8000-000000000002","role":"authenticated"}',
  true
);

DO $storage_outsider_assert$
DECLARE
  v_historical_path text := pg_catalog.current_setting('test.legacy_image_historical_path', true);
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM storage.objects
  WHERE bucket_id = 'character-illustrations' AND name = v_historical_path;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'unrelated authenticated user must not read historical object, got %', v_count;
  END IF;
END;
$storage_outsider_assert$;
ROLLBACK;
