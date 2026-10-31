-- Store creator-managed character portraits and gallery illustrations separately
-- from private character instructions and avatar videos.

create table public.character_illustrations (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  storage_path text not null unique,
  asset_type text not null check (asset_type in ('primary', 'gallery')),
  sort_order smallint not null default 0,
  created_at timestamptz not null default timezone('utc'::text, now()),
  updated_at timestamptz not null default timezone('utc'::text, now()),
  constraint character_illustrations_path_owner_check check (
    storage_path ~* (
      '^' || author_id::text || '/' || character_id::text ||
      '/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
    )
  ),
  constraint character_illustrations_sort_order_check check (
    (asset_type = 'primary' and sort_order = 0)
    or (asset_type = 'gallery' and sort_order between 1 and 5)
  )
);

comment on table public.character_illustrations is
  'Creator-managed character portrait and gallery image metadata. Image bytes live in private Storage bucket character-illustrations; private character instructions remain in character_private_info.';
comment on column public.character_illustrations.storage_path is
  'Private Storage object path: {author_id}/{character_id}/{uuid}.{jpg|jpeg|png|webp}. Never store a public URL.';
comment on column public.character_illustrations.asset_type is
  'primary = one main portrait; gallery = up to five additional illustrations/expression images.';
comment on column public.character_illustrations.sort_order is
  'Primary portrait uses 0; gallery images use unique positions 1..5.';

create unique index character_illustrations_one_primary_per_character_uidx
  on public.character_illustrations (character_id)
  where asset_type = 'primary';

create unique index character_illustrations_gallery_position_uidx
  on public.character_illustrations (character_id, sort_order)
  where asset_type = 'gallery';

create index character_illustrations_character_lookup_idx
  on public.character_illustrations (character_id, asset_type, sort_order);

alter table public.character_illustrations enable row level security;

revoke all on table public.character_illustrations from public, anon, authenticated;
grant select on table public.character_illustrations to anon, authenticated;
grant insert, update, delete on table public.character_illustrations to authenticated;

create policy "Character illustrations visible to eligible viewers"
  on public.character_illustrations
  for select
  to anon, authenticated
  using (
    exists (
      select 1
      from public.characters c
      where c.id = character_illustrations.character_id
        and (
          c.author_id = (select auth.uid())
          or (
            c.visibility = 'public'
            and c.deleted_at is null
            and (
              c.is_nsfw is not true
              or (
                (select auth.uid()) is not null
                and private.current_user_is_adult()
              )
            )
          )
        )
    )
  );

create policy "Authors can add their own character illustrations"
  on public.character_illustrations
  for insert
  to authenticated
  with check (
    author_id = (select auth.uid())
    and public.account_is_active()
    and exists (
      select 1
      from public.characters c
      where c.id = character_illustrations.character_id
        and c.author_id = (select auth.uid())
        and c.deleted_at is null
        and (
          c.is_nsfw is not true
          or private.current_user_is_adult()
        )
    )
  );

create policy "Authors can update their own character illustrations"
  on public.character_illustrations
  for update
  to authenticated
  using (
    author_id = (select auth.uid())
    and public.account_is_active()
    and exists (
      select 1
      from public.characters c
      where c.id = character_illustrations.character_id
        and c.author_id = (select auth.uid())
    )
  )
  with check (
    author_id = (select auth.uid())
    and public.account_is_active()
    and exists (
      select 1
      from public.characters c
      where c.id = character_illustrations.character_id
        and c.author_id = (select auth.uid())
        and c.deleted_at is null
        and (
          c.is_nsfw is not true
          or private.current_user_is_adult()
        )
    )
  );

create policy "Authors can delete their own character illustrations"
  on public.character_illustrations
  for delete
  to authenticated
  using (
    author_id = (select auth.uid())
    and exists (
      select 1
      from public.characters c
      where c.id = character_illustrations.character_id
        and c.author_id = (select auth.uid())
    )
  );

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'character-illustrations',
  'character-illustrations',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
);

create policy "Character illustration owner upload"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'character-illustrations'
    and name ~* (
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
      '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
      '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
    )
    and split_part(name, '/', 1) = (select auth.uid())::text
    and public.account_is_active()
    and exists (
      select 1
      from public.characters c
      where c.id::text = split_part(name, '/', 2)
        and c.author_id = (select auth.uid())
        and c.deleted_at is null
        and (
          c.is_nsfw is not true
          or private.current_user_is_adult()
        )
    )
  );

create policy "Character illustration owner update"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'character-illustrations'
    and split_part(name, '/', 1) = (select auth.uid())::text
    and exists (
      select 1
      from public.characters c
      where c.id::text = split_part(name, '/', 2)
        and c.author_id = (select auth.uid())
    )
  )
  with check (
    bucket_id = 'character-illustrations'
    and name ~* (
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
      '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/' ||
      '[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
    )
    and split_part(name, '/', 1) = (select auth.uid())::text
    and exists (
      select 1
      from public.characters c
      where c.id::text = split_part(name, '/', 2)
        and c.author_id = (select auth.uid())
    )
  );

create policy "Character illustration owner delete"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'character-illustrations'
    and split_part(name, '/', 1) = (select auth.uid())::text
    and exists (
      select 1
      from public.characters c
      where c.id::text = split_part(name, '/', 2)
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
        split_part(name, '/', 1) = (select auth.uid())::text
        and exists (
          select 1
          from public.characters c
          where c.id::text = split_part(name, '/', 2)
            and c.author_id = (select auth.uid())
        )
      )
      or exists (
        select 1
        from public.character_illustrations ci
        join public.characters c on c.id = ci.character_id
        where ci.storage_path = storage.objects.name
          and c.visibility = 'public'
          and c.deleted_at is null
          and (
            c.is_nsfw is not true
            or (
              (select auth.uid()) is not null
              and private.current_user_is_adult()
            )
          )
      )
    )
  );
