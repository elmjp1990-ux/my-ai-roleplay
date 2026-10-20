-- Add leading-column indexes for the two nullable chat foreign keys.
-- These complement the owner-scoped listing indexes and prevent FK checks from scanning the table.
create index if not exists chat_memory_photos_session_id_fkey_idx
  on public.chat_memory_photos (session_id)
  where session_id is not null;

create index if not exists chat_memory_photos_group_id_fkey_idx
  on public.chat_memory_photos (group_id)
  where group_id is not null;
