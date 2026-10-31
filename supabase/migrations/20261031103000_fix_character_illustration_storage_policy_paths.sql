drop policy if exists "Character illustration owner upload" on storage.objects;
drop policy if exists "Character illustration owner update" on storage.objects;
drop policy if exists "Character illustration owner delete" on storage.objects;
drop policy if exists "Character illustrations visible to eligible viewers" on storage.objects;

create policy "Character illustration owner upload"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'character-illustrations'
    and objects.name ~* (
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
      '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
      '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
    )
    and split_part(objects.name, '/', 1) = (select auth.uid())::text
    and public.account_is_active()
    and exists (
      select 1
      from public.characters c
      where c.id::text = split_part(objects.name, '/', 2)
        and c.author_id = (select auth.uid())
        and c.deleted_at is null
        and (c.is_nsfw is not true or private.current_user_is_adult())
    )
  );

create policy "Character illustration owner update"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'character-illustrations'
    and split_part(objects.name, '/', 1) = (select auth.uid())::text
    and exists (
      select 1
      from public.characters c
      where c.id::text = split_part(objects.name, '/', 2)
        and c.author_id = (select auth.uid())
    )
  )
  with check (
    bucket_id = 'character-illustrations'
    and objects.name ~* (
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
      '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
      '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
    )
    and split_part(objects.name, '/', 1) = (select auth.uid())::text
    and exists (
      select 1
      from public.characters c
      where c.id::text = split_part(objects.name, '/', 2)
        and c.author_id = (select auth.uid())
    )
  );

create policy "Character illustration owner delete"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'character-illustrations'
    and split_part(objects.name, '/', 1) = (select auth.uid())::text
    and exists (
      select 1
      from public.characters c
      where c.id::text = split_part(objects.name, '/', 2)
        and c.author_id = (select auth.uid())
    )
  );

create policy "Character illustrations visible to eligible viewers"
  on storage.objects
  for select
  to anon, authenticated
  using (
    bucket_id = 'character-illustrations'
    and (
      (
        split_part(objects.name, '/', 1) = (select auth.uid())::text
        and exists (
          select 1
          from public.characters c
          where c.id::text = split_part(objects.name, '/', 2)
            and c.author_id = (select auth.uid())
        )
      )
      or exists (
        select 1
        from public.character_illustrations ci
        join public.characters c on c.id = ci.character_id
        where ci.storage_path = objects.name
          and c.visibility = 'public'
          and c.deleted_at is null
          and (
            c.is_nsfw is not true
            or ((select auth.uid()) is not null and private.current_user_is_adult())
          )
      )
    )
  );
