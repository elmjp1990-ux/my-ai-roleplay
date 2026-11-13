do $$
declare
  v_characters integer;
  v_metadata integer;
  v_objects integer;
  v_current integer;
  v_historical integer;
  v_total_cleared integer;
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
    and not (character_snapshot ? 'imagePath');
  select count(*) into v_total_cleared
  from public.chat_sessions
  where (id::text like '30000000-0000-4000-8000-%' or id::text like '40000000-0000-4000-8000-%')
    and character_snapshot->>'image' = '';

  if v_characters <> 8 then raise exception 'Expected 8 cleared character avatars, got %', v_characters; end if;
  if v_metadata <> 8 then raise exception 'Expected 8 primary metadata rows, got %', v_metadata; end if;
  if v_objects <> 8 then raise exception 'Expected 8 Storage objects, got %', v_objects; end if;
  if v_current <> 74 then raise exception 'Expected 74 pathified snapshots, got %', v_current; end if;
  if v_historical <> 13 then raise exception 'Expected 13 historical clears, got %', v_historical; end if;
  if v_total_cleared <> 87 then raise exception 'Expected 87 total snapshot clears, got %', v_total_cleared; end if;
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
    and character_snapshot->>'image' = '' and not (character_snapshot ? 'imagePath')) as historical_clears;
