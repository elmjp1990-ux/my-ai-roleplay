grant update (content, deleted_at) on table public.chat_group_messages to authenticated;

drop policy if exists chat_group_messages_update_owner_content on public.chat_group_messages;
create policy chat_group_messages_update_owner_content
on public.chat_group_messages
for update
to authenticated
using (
  exists (
    select 1 from public.chat_groups g
    where g.id = chat_group_messages.group_id
      and g.owner_id = (select auth.uid())
      and g.archived_at is null
  )
)
with check (
  exists (
    select 1 from public.chat_groups g
    where g.id = chat_group_messages.group_id
      and g.owner_id = (select auth.uid())
      and g.archived_at is null
  )
);
