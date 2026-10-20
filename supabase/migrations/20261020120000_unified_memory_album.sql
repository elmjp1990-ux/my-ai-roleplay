-- MEMORY-ALBUM-01: unified private memory photo metadata and storage policies.
-- This migration is staged for review; it has not been applied to the Supabase project.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('personax-memory-photos', 'personax-memory-photos', false, 10485760,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
set public = false,
    file_size_limit = 10485760,
    allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.chat_memory_photos (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  chat_type text not null check (chat_type in ('single','group')),
  session_id uuid references public.chat_sessions(id) on delete cascade,
  group_id uuid references public.chat_groups(id) on delete cascade,
  storage_path text not null unique,
  caption text not null default '回憶快照' check (char_length(caption) between 1 and 80),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '1 year'),
  status text not null default 'active' check (status in ('active','deleting','delete_failed')),
  deletion_attempts integer not null default 0 check (deletion_attempts >= 0),
  last_deletion_error text,
  deleted_at timestamptz,
  constraint chat_memory_photos_scope_check check (
    (chat_type = 'single' and session_id is not null and group_id is null)
    or (chat_type = 'group' and group_id is not null and session_id is null)
  )
);

-- Enforce the retention window server-side; clients cannot choose a later expiry.
create or replace function public.enforce_chat_memory_photo_expiry()
returns trigger
language plpgsql
set search_path = ''
as $
begin
  new.created_at := pg_catalog.now();
  new.expires_at := new.created_at + interval '1 year';
  new.status := 'active';
  new.deletion_attempts := 0;
  new.last_deletion_error := null;
  new.deleted_at := null;
  return new;
end;
$;

revoke all on function public.enforce_chat_memory_photo_expiry() from public, anon, authenticated;

drop trigger if exists enforce_chat_memory_photo_expiry on public.chat_memory_photos;
create trigger enforce_chat_memory_photo_expiry
before insert on public.chat_memory_photos
for each row execute function public.enforce_chat_memory_photo_expiry();

create index if not exists chat_memory_photos_single_active_idx
  on public.chat_memory_photos (owner_id, session_id, created_at desc)
  where status = 'active' and deleted_at is null;
create index if not exists chat_memory_photos_group_active_idx
  on public.chat_memory_photos (owner_id, group_id, created_at desc)
  where status = 'active' and deleted_at is null;
create index if not exists chat_memory_photos_expiry_idx
  on public.chat_memory_photos (expires_at)
  where status in ('active','delete_failed') and deleted_at is null;

alter table public.chat_memory_photos enable row level security;
revoke all on public.chat_memory_photos from anon;
grant select, insert, delete on public.chat_memory_photos to authenticated;

drop policy if exists "memory_photos_select_owner" on public.chat_memory_photos;
create policy "memory_photos_select_owner" on public.chat_memory_photos
for select to authenticated
using (
  owner_id = (select auth.uid())
  and deleted_at is null
  and (
    (chat_type = 'single' and exists (
      select 1 from public.chat_sessions s
      where s.id = session_id and s.user_id = (select auth.uid()) and s.deleted_at is null
    ))
    or
    (chat_type = 'group' and exists (
      select 1 from public.chat_groups g
      where g.id = group_id and g.owner_id = (select auth.uid()) and g.archived_at is null
    ))
  )
);

drop policy if exists "memory_photos_insert_owner" on public.chat_memory_photos;
create policy "memory_photos_insert_owner" on public.chat_memory_photos
for insert to authenticated
with check (
  owner_id = (select auth.uid())
  and status = 'active' and deleted_at is null
  and expires_at > created_at
  and (
    (chat_type = 'single' and exists (
      select 1 from public.chat_sessions s
      where s.id = session_id and s.user_id = (select auth.uid()) and s.deleted_at is null
    ))
    or
    (chat_type = 'group' and exists (
      select 1 from public.chat_groups g
      where g.id = group_id and g.owner_id = (select auth.uid()) and g.archived_at is null
    ))
  )
);

-- No client UPDATE policy: immutable photo scope/path/expiry fields are managed by trusted server-side cleanup only.
drop policy if exists "memory_photos_update_owner" on public.chat_memory_photos;

drop policy if exists "memory_photos_delete_owner" on public.chat_memory_photos;
create policy "memory_photos_delete_owner" on public.chat_memory_photos
for delete to authenticated
using (owner_id = (select auth.uid()));

-- Storage paths are {owner UUID}/{single|group}/{session or group UUID}/{random filename}.
drop policy if exists "memory_photo_objects_select_owner" on storage.objects;
create policy "memory_photo_objects_select_owner" on storage.objects
for select to authenticated
using (
  bucket_id = 'personax-memory-photos'
  and split_part(name, '/', 1) = (select auth.uid())::text
  and (
    (split_part(name, '/', 2) = 'single' and exists (
      select 1 from public.chat_sessions s
      where s.id::text = split_part(name, '/', 3)
        and s.user_id = (select auth.uid()) and s.deleted_at is null
    ))
    or
    (split_part(name, '/', 2) = 'group' and exists (
      select 1 from public.chat_groups g
      where g.id::text = split_part(name, '/', 3)
        and g.owner_id = (select auth.uid()) and g.archived_at is null
    ))
  )
);

drop policy if exists "memory_photo_objects_insert_owner" on storage.objects;
create policy "memory_photo_objects_insert_owner" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'personax-memory-photos'
  and split_part(name, '/', 1) = (select auth.uid())::text
  and (
    (split_part(name, '/', 2) = 'single' and exists (
      select 1 from public.chat_sessions s
      where s.id::text = split_part(name, '/', 3)
        and s.user_id = (select auth.uid()) and s.deleted_at is null
    ))
    or
    (split_part(name, '/', 2) = 'group' and exists (
      select 1 from public.chat_groups g
      where g.id::text = split_part(name, '/', 3)
        and g.owner_id = (select auth.uid()) and g.archived_at is null
    ))
  )
);

drop policy if exists "memory_photo_objects_delete_owner" on storage.objects;
create policy "memory_photo_objects_delete_owner" on storage.objects
for delete to authenticated
using (
  bucket_id = 'personax-memory-photos'
  and split_part(name, '/', 1) = (select auth.uid())::text
  and (
    (split_part(name, '/', 2) = 'single' and exists (
      select 1 from public.chat_sessions s
      where s.id::text = split_part(name, '/', 3)
        and s.user_id = (select auth.uid())
    ))
    or
    (split_part(name, '/', 2) = 'group' and exists (
      select 1 from public.chat_groups g
      where g.id::text = split_part(name, '/', 3)
        and g.owner_id = (select auth.uid())
    ))
  )
);
