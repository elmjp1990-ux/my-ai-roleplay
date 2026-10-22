-- Cloud persistence for group sweet diaries. Local browser storage remains a cache/offline fallback.
create table if not exists public.chat_group_diary (
  group_id uuid primary key references public.chat_groups(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  memories jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  constraint chat_group_diary_memories_array check (jsonb_typeof(memories) = 'array')
);
alter table public.chat_group_diary enable row level security;
revoke all on public.chat_group_diary from public, anon;
grant select, insert, update on public.chat_group_diary to authenticated;
drop policy if exists chat_group_diary_owner_select on public.chat_group_diary;
create policy chat_group_diary_owner_select on public.chat_group_diary
for select to authenticated
using (owner_id = (select auth.uid()) and exists (
  select 1 from public.chat_groups g where g.id = chat_group_diary.group_id and g.owner_id = (select auth.uid())
));
drop policy if exists chat_group_diary_owner_insert on public.chat_group_diary;
create policy chat_group_diary_owner_insert on public.chat_group_diary
for insert to authenticated
with check (owner_id = (select auth.uid()) and exists (
  select 1 from public.chat_groups g where g.id = chat_group_diary.group_id and g.owner_id = (select auth.uid())
));
drop policy if exists chat_group_diary_owner_update on public.chat_group_diary;
create policy chat_group_diary_owner_update on public.chat_group_diary
for update to authenticated
using (owner_id = (select auth.uid()) and exists (
  select 1 from public.chat_groups g where g.id = chat_group_diary.group_id and g.owner_id = (select auth.uid())
))
with check (owner_id = (select auth.uid()) and exists (
  select 1 from public.chat_groups g where g.id = chat_group_diary.group_id and g.owner_id = (select auth.uid())
));
-- Support efficient owner-scoped foreign-key maintenance.
create index if not exists chat_group_diary_owner_id_idx on public.chat_group_diary(owner_id);
