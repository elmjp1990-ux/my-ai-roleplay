-- Keep roleplay secrets out of the client-readable characters table.
-- Backfill legacy values before removing the legacy column.
begin;

insert into public.character_private_info as existing (character_id, author_id, private_info)
select c.id, c.author_id, c.private_info
from public.characters c
where coalesce(c.private_info, '') <> ''
on conflict (character_id) do update
set author_id = excluded.author_id,
    private_info = excluded.private_info
where coalesce(existing.private_info, '') = '';

alter table public.character_private_info enable row level security;

revoke all on table public.character_private_info from anon;
grant select, insert, update, delete on table public.character_private_info to authenticated;

drop policy if exists "Authors manage their own character private info"
  on public.character_private_info;

create policy "Authors manage their own character private info"
on public.character_private_info
for all
to authenticated
using (
  author_id = (select auth.uid())
  and exists (
    select 1
    from public.characters c
    where c.id = character_private_info.character_id
      and c.author_id = (select auth.uid())
  )
)
with check (
  author_id = (select auth.uid())
  and exists (
    select 1
    from public.characters c
    where c.id = character_private_info.character_id
      and c.author_id = (select auth.uid())
  )
);

alter table public.characters drop column if exists private_info;

commit;
